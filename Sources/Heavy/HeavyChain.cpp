#include "HeavyChain.h"
#include "HeavyTuning.h"
#include <Accelerate/Accelerate.h>
#include <rubberband/rubberband-c.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

const double LookAheadMs = 350;
const double LimiterCeiling = 0.966;  // -0.3 dBFS

// Times in ms. Chosen on the test set.
struct Settings {
    double fadeMs = 15, jumpMinMs = 4, jumpMaxMs = 60, matchMs = 25, toleranceMs = 12, holdMs = 25, guardMs = 5;
    double matchLowHz = 100, matchHighHz = 5000;  // what the matching listens to
    double sensitivity = 1.5;                     // lower finds more hits
    double lateMs = 40;       // a jump before a hit waits until this close to the end of the gap, where the note is settled
    double heldMinMs = 30;    // with no hit in sight, wait for a jump this big
    double heldFadeMs = 20;   // and fade it this slowly
    // Going down, a jump skips ahead, and bigger jumps join best.
    double downJumpMaxMs = 160, downHeldMinMs = 120, downHeldFadeMs = 40;
    double cutHz = 600;       // the lower sound's route carries what is below this
    bool split = true;        // the lower sound takes its own route
    double limitLookMs = 10, limitReleaseMs = 300;  // the safety limiter
    // A jump that missed its hit by less than this is left alone, and the next gap makes up the rest. Jumping again
    // for the same hit, often back the other way, makes two or three joins where one would do. Going up by more than
    // settleUpTo half-steps every hit is still put right, because there the drums need it.
    double settleMs = 8, settleUpTo = 2.5;
    double offCost = 0.3;     // how much a join's likeness is marked down for missing its hit by the full tolerance
};

double bessel0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 30; k++) { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; }
    return sum;
}

// Finds hits as a sudden rise across the spectrum, which works on loud masters, where the level hardly moves at a hit.
// A hit is known about 50 ms after it arrives.
struct HitFinder {
    static constexpr int Median = 31, MedianMiddle = 15, Around = 8;
    int size = 1024, log2Size = 10, hop = 128, fill = 0, frames = 0, sinceHit = 1 << 20, minGap = 22;
    FFTSetup fft = nullptr;
    std::vector<float> window, buffer, scratch, re, im, previous, magnitude;
    float rises[Median] = {}, sorted[Median] = {}, recent[Around * 2 + 1] = {};
    double mean = 0, variance = 1, sensitivity = 1.5;

    void init(double rate, int scale) {
        size = 1024 * scale; hop = 128 * scale;
        log2Size = int(std::lround(std::log2(double(size))));
        fft = vDSP_create_fftsetup(log2Size, kFFTRadix2);
        window.resize(size); buffer.assign(size, 0); scratch.resize(size);
        re.resize(size / 2); im.resize(size / 2); previous.assign(size / 2 + 1, 0); magnitude.resize(size / 2 + 1);
        float sum = 0;
        for (int i = 0; i < size; i++) { window[i] = 0.5f - 0.5f * std::cos(2 * float(M_PI) * i / size); sum += window[i]; }
        for (auto &w : window) w /= sum / 2;
        minGap = int(0.06 * rate / hop);
    }
    ~HitFinder() { if (fft) vDSP_destroy_fftsetup(fft); }

    // One sample in. Returns how many samples ago a hit was, or -1.
    int push(float mono) {
        buffer[fill++] = mono;
        if (fill < size) return -1;
        vDSP_vmul(buffer.data(), 1, window.data(), 1, scratch.data(), 1, vDSP_Length(size));
        for (int i = 0; i < size / 2; i++) { re[i] = scratch[2 * i]; im[i] = scratch[2 * i + 1]; }
        DSPSplitComplex z{re.data(), im.data()};
        vDSP_fft_zrip(fft, &z, 1, log2Size, kFFTDirection_Forward);
        magnitude[0] = std::log1p(100 * std::fabs(re[0]) * 0.5f);
        magnitude[size / 2] = std::log1p(100 * std::fabs(im[0]) * 0.5f);
        for (int i = 1; i < size / 2; i++) magnitude[i] = std::log1p(100 * 0.5f * std::sqrt(re[i] * re[i] + im[i] * im[i]));
        float rise = 0;
        for (int i = 0; i <= size / 2; i++) { float d = magnitude[i] - previous[i]; if (d > 0) rise += d; previous[i] = magnitude[i]; }
        std::memmove(buffer.data(), buffer.data() + hop, sizeof(float) * (size - hop));
        fill = size - hop;
        std::memmove(rises, rises + 1, sizeof(float) * (Median - 1));
        rises[Median - 1] = rise;
        frames++; sinceHit++;
        // The frame in the middle, against the median around it.
        std::copy(rises, rises + Median, sorted);
        std::nth_element(sorted, sorted + MedianMiddle, sorted + Median);
        float value = rises[Median - 1 - MedianMiddle] - sorted[MedianMiddle];
        std::memmove(recent, recent + 1, sizeof(float) * (Around * 2));
        recent[Around * 2] = value;
        const double a = 1.0 / 1500;  // about 4 s of memory
        mean += a * (value - mean);
        variance += a * ((value - mean) * (value - mean) - variance);
        if (frames < 60 || variance < 1e-12) return -1;
        float middle = recent[Around];
        if (middle <= 1e-6f || middle < mean + sensitivity * std::sqrt(variance) || sinceHit < minGap) return -1;
        for (float r : recent) if (r > middle) return -1;
        sinceHit = 0;
        return size / 2 + (MedianMiddle + Around) * hop;
    }
};

// Reads a ring of sound at any position, with a filter that leaves out what would fold back when reading fast.
struct TapeReader {
    static constexpr int Taps = 48, Half = Taps / 2, Phases = 256;
    std::vector<float> table;
    void init() { table.assign(size_t(Phases + 1) * Taps, 0.f); }
    // No memory is made here. Only exactly 1 gives an untouched sound, so nothing else is cut at the same frequency.
    void setSpeed(double speed) {
        double cut = speed == 1 ? 1.0 : 0.97 * std::min(1.0, 1.0 / speed);
        for (int p = 0; p <= Phases; p++) {
            double fraction = double(p) / Phases, sum = 0;
            float *row = &table[size_t(p) * Taps];
            for (int k = 0; k < Taps; k++) {
                double x = k - (Half - 1) - fraction, s = std::fabs(x) < 1e-9 ? cut : std::sin(M_PI * cut * x) / (M_PI * x);
                double u = x / Half, w = std::fabs(u) >= 1 ? 0 : bessel0(9.0 * std::sqrt(1 - u * u)) / bessel0(9.0);
                row[k] = float(s * w);
                sum += s * w;
            }
            for (int k = 0; k < Taps; k++) row[k] = float(row[k] / sum);
        }
    }
    inline float read(const float *ring, int64_t mask, double position) const {
        int64_t whole = int64_t(std::floor(position));
        double f = (position - whole) * Phases;
        int p = int(f);
        float blend = float(f - p);
        const float *row0 = &table[size_t(p) * Taps], *row1 = row0 + Taps;
        float s0 = 0, s1 = 0;
        int64_t start = whole - (Half - 1);
        for (int k = 0; k < Taps; k++) {
            float v = ring[(start + k) & mask];
            s0 += row0[k] * v; s1 += row1[k] * v;
        }
        return s0 + blend * (s1 - s0);
    }
};

// The same safety limiter as Advanced processing: 2 ms of look-ahead, gain back in 25 ms after a short over, else 120 ms.
struct Limiter {
    int look = 96, length = 97, position = 0;
    double release = 0.9998, fastRelease = 0.999, gainHeld = 1, sum = 97;
    int64_t sinceOver = 1 << 30, episode = 0, shortOver = 240;
    std::vector<float> delay[2];
    std::vector<double> need, held;

    void init(double rate) {
        look = std::max(1, int(std::lround(0.002 * rate))); length = look + 1;
        release = std::exp(-1.0 / (0.120 * rate)); fastRelease = std::exp(-1.0 / (0.025 * rate));
        shortOver = int64_t(std::lround(0.005 * rate));
        reset();
    }
    void reset() {
        delay[0].assign(length, 0.f); delay[1].assign(length, 0.f);
        need.assign(length, 1.0); held.assign(length, 1.0);
        sum = length; gainHeld = 1; position = 0; sinceOver = 1 << 30; episode = 0;
    }
    inline void run(float &left, float &right) {
        double peak = std::max(std::fabs(double(left)), std::fabs(double(right)));
        double wanted = peak > LimiterCeiling ? LimiterCeiling * (1.0 - 4e-6) / peak : 1.0;
        need[position] = wanted;
        if (wanted < 1.0 && sinceOver > look) episode = 0;
        sinceOver = wanted < 1.0 ? 0 : sinceOver + 1;
        double lowest = 1.0;
        if (sinceOver <= look) { for (int k = 0; k < length; k++) lowest = std::min(lowest, need[k]); episode++; }
        if (lowest < gainHeld) gainHeld = lowest;
        else {
            gainHeld = lowest - (lowest - gainHeld) * (episode < shortOver ? fastRelease : release);
            if (lowest == 1.0 && gainHeld > 1.0 - 1e-7) gainHeld = 1.0;
        }
        sum += gainHeld - held[position]; held[position] = gainHeld;
        double gain = std::min(1.0, sum / length);
        int oldest = position + 1 == length ? 0 : position + 1;
        delay[0][position] = left; delay[1][position] = right;
        float l = delay[0][oldest], r = delay[1][oldest];
        if (gain < 1.0) {
            l = float(std::max(-LimiterCeiling, std::min(LimiterCeiling, l * gain)));
            r = float(std::max(-LimiterCeiling, std::min(LimiterCeiling, r * gain)));
        }
        left = l; right = r;
        if (++position == length) {  // add the gains up again once per lap, so rounding never builds up
            position = 0;
            sum = 0;
            for (int k = 0; k < length; k++) sum += held[k];
        }
    }
};

// Super Advanced's own safety limiter. Its two routes, joined again, no longer line up the way the song's mastering
// left them, so a loud song's peaks can go a few dB over full scale. A limiter that pulls those down within 2 ms and
// lets go within 25 ms changes the gain inside each bass wave, which is heard as distortion. This one looks further
// ahead, lowers the gain along a smooth curve, and lets it back up slowly.
struct SmoothLimiter {
    int look = 240, length = 241, firstLength = 121, secondLength = 121;
    double release = 0.9999, holdValue = 1, firstSum = 121, sum = 121;
    int64_t now = 0;
    int position = 0, first = 0, second = 0, front = 0, count = 0;
    std::vector<float> delay[2];
    std::vector<double> need, held, smoothed;
    std::vector<int64_t> rising;  // for the lowest need: times whose needs rise, oldest first (a ring)

    void init(double rate, double lookMs, double releaseMs) {
        look = std::max(2, int(std::lround(lookMs * 0.001 * rate)) & ~1); length = look + 1;
        firstLength = look / 2 + 1; secondLength = look - firstLength + 2;
        release = std::exp(-1.0 / (releaseMs * 0.001 * rate));
        delay[0].assign(length, 0.f); delay[1].assign(length, 0.f);
        need.assign(length, 1.0); held.assign(firstLength, 1.0); smoothed.assign(secondLength, 1.0); rising.assign(length, 0);
        holdValue = 1; firstSum = firstLength; sum = secondLength;
        now = 0; position = first = second = front = count = 0;
    }
    inline void run(float &left, float &right) {
        double peak = std::max(std::fabs(double(left)), std::fabs(double(right)));
        double wanted = peak > LimiterCeiling ? LimiterCeiling * (1.0 - 4e-6) / peak : 1.0;
        // The lowest need of the last `length` samples.
        if (count > 0 && rising[front] <= now - length) { front = front + 1 == length ? 0 : front + 1; count--; }
        need[position] = wanted;
        while (count > 0 && need[rising[(front + count - 1) % length] % length] >= wanted) count--;
        rising[(front + count) % length] = now; count++;
        double lowest = need[rising[front] % length];
        holdValue = lowest < holdValue ? lowest : lowest - (lowest - holdValue) * release;
        if (lowest == 1.0 && holdValue > 1.0 - 1e-7) holdValue = 1.0;
        // Two running averages one after the other: the gain eases down along an S-curve, and is low enough by the
        // time the peak comes out.
        firstSum += holdValue - held[first]; held[first] = holdValue;
        double eased = firstSum / firstLength;
        sum += eased - smoothed[second]; smoothed[second] = eased;
        double gain = std::min(1.0, sum / secondLength);
        int oldest = position + 1 == length ? 0 : position + 1;
        delay[0][position] = left; delay[1][position] = right;
        float l = delay[0][oldest], r = delay[1][oldest];
        if (gain < 1.0) {
            l = float(std::max(-LimiterCeiling, std::min(LimiterCeiling, l * gain)));
            r = float(std::max(-LimiterCeiling, std::min(LimiterCeiling, r * gain)));
        }
        left = l; right = r;
        now++;
        if (++position == length) position = 0;
        if (++first == firstLength) {  // add the gains up again once per lap, so rounding never builds up
            first = 0; firstSum = 0;
            for (double v : held) firstSum += v;
        }
        if (++second == secondLength) {
            second = 0; sum = 0;
            for (double v : smoothed) sum += v;
        }
    }
};

// Cuts the sound with a filter that adds back exactly. Below the cut, jumps are heard as a wobble, because the strong
// low notes are too few and too steady to hide them. That part goes through Rubber Band and stays at true time. Above
// the cut the tape keeps the sharp pulses that make a distorted guitar sound clean.
struct LowRoute {
    static constexpr int Hop = 1024;
    int taps = 2401, half = 1200, fftSize = 4096, log2Size = 12, fill = 0;
    FFTSetup fft = nullptr;
    RubberBandState shifter = nullptr;
    std::vector<float> filterRe, filterIm, re, im, scratch, history[2], gathered[2], low[2], high[2], delayLine[2];
    int64_t delayAt = 0;
    std::vector<float> plain[2], shifted[2];   // the lower sound as it came, and through Rubber Band
    float *outs[2] = {nullptr, nullptr};
    const float *lowIn[2] = {nullptr, nullptr};
    std::vector<float> retrieved[2];
    int64_t size = 0, mask = 0, shiftedCount = 0, primed = 0;
    int offset = 0, oldOffset = 0, offsetFade = 0, fadeFrames = 960;
    double blend = 0, blendStep = 0;

    void design(double rate, double cutHz) {
        std::vector<float> h(fftSize, 0.f);
        double sum = 0, m = half;
        for (int i = 0; i < taps; i++) {
            double x = i - m, s = std::fabs(x) < 1e-9 ? 2 * cutHz / rate : std::sin(2 * M_PI * cutHz / rate * x) / (M_PI * x);
            double u = x / (m + 1), w = bessel0(9.0 * std::sqrt(std::max(0.0, 1 - u * u))) / bessel0(9.0);
            h[i] = float(s * w); sum += s * w;
        }
        for (auto &v : h) v = float(v / sum);
        for (int i = 0; i < fftSize / 2; i++) { filterRe[i] = h[2 * i]; filterIm[i] = h[2 * i + 1]; }
        DSPSplitComplex z{filterRe.data(), filterIm.data()};
        vDSP_fft_zrip(fft, &z, 1, log2Size, kFFTDirection_Forward);
    }

    void init(double rate, int64_t ringSize, double cutHz) {
        taps = int(0.05 * rate) | 1;
        half = (taps - 1) / 2;
        fftSize = 1024; log2Size = 10;
        while (fftSize < taps + Hop) { fftSize *= 2; log2Size++; }
        fft = vDSP_create_fftsetup(log2Size, kFFTRadix2);
        re.resize(fftSize / 2); im.resize(fftSize / 2); scratch.resize(fftSize);
        filterRe.resize(fftSize / 2); filterIm.resize(fftSize / 2);
        design(rate, cutHz);
        for (int c = 0; c < 2; c++) {
            history[c].assign(fftSize, 0.f); gathered[c].assign(Hop, 0.f); low[c].assign(Hop, 0.f); high[c].assign(Hop, 0.f);
            delayLine[c].assign(half, 0.f);
            plain[c].assign(ringSize, 0.f); shifted[c].assign(ringSize, 0.f); retrieved[c].assign(4096, 0.f);
        }
        size = ringSize; mask = ringSize - 1;
        fadeFrames = int(0.02 * rate);
        blendStep = 1.0 / fadeFrames;
        shifter = rubberband_new((unsigned)std::lround(rate), 2,
                                 RubberBandOptionProcessRealTime | RubberBandOptionEngineFiner | RubberBandOptionChannelsTogether |
                                     RubberBandOptionPitchHighConsistency, 1.0, 1.0);
        rubberband_set_max_process_size(shifter, Hop);
        offset = oldOffset = rubberbandOffset();
        // Rubber Band makes memory when it first gives out sound, so that happens here. The real stream starts after it.
        std::vector<float> quiet(Hop, 0.f);
        const float *silence[2] = {quiet.data(), quiet.data()};
        while (shiftedCount == 0) {
            rubberband_process(shifter, silence, Hop, 0);
            primed += Hop;
            collect();
        }
    }
    ~LowRoute() {
        if (fft) vDSP_destroy_fftsetup(fft);
        if (shifter) rubberband_delete(shifter);
    }
    // Where a sample comes out of Rubber Band, against where it went in. It moves with the amount.
    int rubberbandOffset() const {
        return int(rubberband_get_start_delay(shifter)) - int(rubberband_get_preferred_start_pad(shifter));
    }
    // At normal pitch this route skips Rubber Band, so it keeps its last pitch: leaving exactly 1 makes a break in the sound.
    void setSpeed(double speed) {
        if (speed == 1) return;
        rubberband_set_pitch_scale(shifter, speed);
        int now = rubberbandOffset();
        if (now != offset) { oldOffset = offset; offset = now; offsetFade = fadeFrames; }
    }
    // One sample in. True when a Hop of low and high is ready.
    bool push(float left, float right) {
        gathered[0][fill] = left; gathered[1][fill] = right;
        if (++fill < Hop) return false;
        fill = 0;
        for (int c = 0; c < 2; c++) {
            float *h = history[c].data();
            std::memmove(h, h + Hop, sizeof(float) * (fftSize - Hop));
            std::memcpy(h + fftSize - Hop, gathered[c].data(), sizeof(float) * Hop);
            for (int i = 0; i < fftSize / 2; i++) { re[i] = h[2 * i]; im[i] = h[2 * i + 1]; }
            DSPSplitComplex z{re.data(), im.data()};
            vDSP_fft_zrip(fft, &z, 1, log2Size, kFFTDirection_Forward);
            float dc = re[0] * filterRe[0], top = im[0] * filterIm[0];
            for (int i = 1; i < fftSize / 2; i++) {
                float a = re[i] * filterRe[i] - im[i] * filterIm[i], b = re[i] * filterIm[i] + im[i] * filterRe[i];
                re[i] = a; im[i] = b;
            }
            re[0] = dc; im[0] = top;
            vDSP_fft_zrip(fft, &z, 1, log2Size, kFFTDirection_Inverse);
            for (int i = 0; i < fftSize / 2; i++) { scratch[2 * i] = re[i]; scratch[2 * i + 1] = im[i]; }
            float scale = 1.f / (4 * fftSize);
            int64_t at = delayAt;
            float *d = delayLine[c].data();
            for (int i = 0; i < Hop; i++) {
                float l = scratch[fftSize - Hop + i] * scale;
                float x = gathered[c][i];
                float old = d[(at + i) % half];
                d[(at + i) % half] = x;
                low[c][i] = l; high[c][i] = old - l;
            }
        }
        delayAt = (delayAt + Hop) % half;
        return true;
    }
    // After push returned true: the lower sound goes through Rubber Band. `count` is how many came before it.
    void shiftLows(int64_t count) {
        for (int c = 0; c < 2; c++) {
            lowIn[c] = low[c].data();
            for (int i = 0; i < Hop; i++) plain[c][(count + i) & mask] = low[c][i];
        }
        rubberband_process(shifter, lowIn, Hop, 0);
        collect();
    }
    void collect() {
        int available;
        while ((available = rubberband_available(shifter)) > 0) {
            int n = std::min(available, 4096);
            outs[0] = retrieved[0].data(); outs[1] = retrieved[1].data();
            int got = int(rubberband_retrieve(shifter, outs, unsigned(n)));
            for (int c = 0; c < 2; c++)
                for (int i = 0; i < got; i++) shifted[c][(shiftedCount + i) & mask] = retrieved[c][i];
            shiftedCount += got;
        }
    }
    inline float readShifted(int c, int64_t position) const {
        position += primed;
        return position >= 0 && position < shiftedCount ? shifted[c][position & mask] : 0.f;
    }
    // The lower sound for position `k`. At normal pitch it skips Rubber Band, so the sound is untouched.
    inline void read(int64_t k, bool shifting, float &left, float &right) {
        if (shifting) blend = std::min(1.0, blend + blendStep); else blend = std::max(0.0, blend - blendStep);
        float out[2] = {0, 0};
        for (int c = 0; c < 2; c++) {
            float plainLow = k >= 0 ? plain[c][k & mask] : 0.f;
            if (blend <= 0) { out[c] = plainLow; continue; }
            float v = readShifted(c, k + offset);
            if (offsetFade > 0) {
                float t = float(offsetFade) / fadeFrames;
                v = v * (1 - t) + readShifted(c, k + oldOffset) * t;
            }
            out[c] = float(blend) * v + float(1 - blend) * plainLow;
        }
        if (offsetFade > 0) offsetFade--;
        left += out[0]; right += out[1];
    }
};

}  // namespace

struct HeavyChain {
    Settings set;
    double rate = 48000, speed = 1, semis = 0;
    int delay = 19000, hitStep = 120, fadeLength = 720;
    int64_t size = 1 << 18, mask = (1 << 18) - 1, written = 0, played = 0;
    std::vector<float> ring[2], match[2], quarter[2];
    std::vector<uint8_t> hits;
    TapeReader reader;
    HitFinder finder;
    SmoothLimiter limiter;
    double head = 0, nextHead = 0;
    int fade = -1, waitAfterJump = 0;
    float likeness = 1;
    double lowState[2] = {0, 0}, highState[2] = {0, 0}, lowK = 0, highK = 0;
    float quarterSum[2] = {0, 0};
    int fadeNow = 720, planFade = 720;
    LowRoute route;
    int tapeDelay = 16800, lookAhead = 16800;
    bool planned = false;
    double planAt = 0, planJump = 0, planLikeness = 0;
    int64_t planHit = -1, aimedHit = -1;
    long long jumps = 0, forced = 0;
    double likenessSum = 0;
    std::vector<long long> jumpLog;

    void applySettings() {
        lowK = 1 - std::exp(-2 * M_PI * set.matchLowHz / rate);
        highK = 1 - std::exp(-2 * M_PI * set.matchHighHz / rate);
        finder.sensitivity = set.sensitivity;
    }

    void setSemis(double value) {
        semis = std::max(-24.0, std::min(24.0, value));
        speed = semis == 0 ? 1.0 : std::pow(2.0, semis / 12);
        reader.setSpeed(speed);
        fadeLength = std::max(16, int(set.fadeMs * 0.001 * rate / std::max(1.0, speed)));
        route.setSpeed(speed);
        planned = false;
    }

    void applyDelay() {
        lookAhead = int(LookAheadMs * 0.001 * rate);
        tapeDelay = lookAhead + (set.split ? LowRoute::Hop : 0);
        delay = tapeDelay + (set.split ? route.half : 0);
        head = -double(tapeDelay);
    }

    // The sound on its way in. Split: the upper part goes to the tape, a Hop at a time, the lower part to Rubber Band.
    void take(const float *left, const float *right, int frames) {
        if (!set.split) { push(left, right, frames); return; }
        for (int i = 0; i < frames; i++) {
            if (!route.push(left[i], right[i])) continue;
            route.shiftLows(written);
            push(route.high[0].data(), route.high[1].data(), LowRoute::Hop);
        }
    }

    // Hits are found in what the tape plays: only those can be repeated or skipped.
    void push(const float *left, const float *right, int frames) {
        for (int i = 0; i < frames; i++, written++) {
            ring[0][written & mask] = left[i]; ring[1][written & mask] = right[i];
            if (written % hitStep == 0) hits[(written / hitStep) % int64_t(hits.size())] = 0;  // a ring: last lap's hits are old
            for (int c = 0; c < 2; c++) {
                double v = c ? right[i] : left[i];
                lowState[c] += lowK * (v - lowState[c]);
                highState[c] += highK * (v - lowState[c] - highState[c]);
                match[c][written & mask] = float(highState[c]);
                quarterSum[c] += float(highState[c]);
                if ((written & 3) == 3) { quarter[c][(written >> 2) & (size / 4 - 1)] = quarterSum[c] * 0.25f; quarterSum[c] = 0; }
            }
            int ago = finder.push(0.5f * (left[i] + right[i]));
            if (ago >= 0 && ago < written)
                hits[((written - ago) / hitStep) % int64_t(hits.size())] = 1;
        }
        // Long digital silence must not sink the filters into very small numbers, which are slow on Intel.
        for (int c = 0; c < 2; c++) {
            if (std::fabs(lowState[c]) < 1e-20) lowState[c] = 0;
            if (std::fabs(highState[c]) < 1e-20) highState[c] = 0;
        }
    }

    int64_t hitAfter(double from, double to) const {
        for (int64_t k = int64_t(from) / hitStep + 1; k <= int64_t(to) / hitStep; k++)
            if (k >= 0 && hits[k % int64_t(hits.size())]) return k * hitStep;
        return -1;
    }

    int64_t hitBefore(double from, double reach) const {
        for (int64_t k = int64_t(from) / hitStep; k >= int64_t(from - reach) / hitStep; k--)
            if (k >= 0 && hits[k % int64_t(hits.size())]) return k * hitStep;
        return -(int64_t(1) << 40);
    }

    // How alike the sound is at position and at position + jump, -1 to 1, at a quarter of the rate.
    double likenessRough(int64_t position, int jump, int length) const {
        const int64_t m = size / 4 - 1;
        int64_t a = position >> 2, b = (position + jump) >> 2;
        double ab = 0, aa = 1e-9, bb = 1e-9;
        for (int c = 0; c < 2; c++) {
            const float *d = quarter[c].data();
            float s1 = 0, s2 = 0, s3 = 0;
            for (int i = 0; i < length; i++) { float u = d[(a + i) & m], v = d[(b + i) & m]; s1 += u * v; s2 += u * u; s3 += v * v; }
            ab += s1; aa += s2; bb += s3;
        }
        return ab / std::sqrt(aa * bb);
    }

    double likenessExact(int64_t position, int jump, int length) const {
        double ab = 0, aa = 1e-9, bb = 1e-9;
        for (int c = 0; c < 2; c++) {
            const float *d = match[c].data();
            float s1 = 0, s2 = 0, s3 = 0;
            for (int i = 0; i < length; i++) { float u = d[(position + i) & mask], v = d[(position + jump + i) & mask]; s1 += u * v; s2 += u * u; s3 += v * v; }
            ab += s1; aa += s2; bb += s3;
        }
        return ab / std::sqrt(aa * bb);
    }

    void jump(double by, double alike) {
        nextHead = head + by;
        fade = 0;
        fadeNow = planned ? planFade : fadeLength;
        likeness = float(std::max(0.0, std::min(1.0, alike)));
        waitAfterJump = int(set.jumpMinMs * 0.001 * rate);
        planned = false;
        if (jumpLog.size() < jumpLog.capacity()) jumpLog.push_back(played);  // checks only: never grows
        jumps++; likenessSum += likeness;
    }

    // Finds the jump that lands the next hit on time, and the moment in the gap where it joins best.
    void plan() {
        double trueTime = double(played) - tapeDelay;
        if (trueTime < 0) return;
        double error = head - trueTime;
        if (speed == 1) {  // at 0 the head sits exactly on true time, so the sound is untouched
            if (error != 0) { jump(-error, 1); nextHead = trueTime; }
            return;
        }
        // Safety: the head must never reach sound that hasn't arrived.
        if (std::fabs(error) > 0.85 * lookAhead) { jump(-error, 0); forced++; return; }
        if (planned) {
            if (head >= planAt) { if (planHit >= 0) aimedHit = planHit; jump(planJump, planLikeness); }
            return;
        }
        double fadeRead = fadeLength * speed, guard = set.guardMs * 0.001 * rate, hold = set.holdMs * 0.001 * rate;
        double seen = double(written) - 64;
        if (seen - head < fadeRead + guard) return;
        // The jump that lands `target` on time; the same at any moment in the gap.
        auto needFor = [&](double target) { return (target - speed * (target - trueTime)) - head; };
        int64_t hitAt = hitAfter(head + fadeRead + guard, seen);
        if (hitAt >= 0 && hitAt == aimedHit && semis <= set.settleUpTo && std::fabs(needFor(double(hitAt))) < set.settleMs * 0.001 * rate)
            hitAt = hitAfter(double(aimedHit), seen);
        bool real = hitAt >= 0;
        double target = real ? double(hitAt) : seen;
        double need = needFor(target);
        bool down = speed < 1;
        int minJump = int(set.jumpMinMs * 0.001 * rate), maxJump = int((down ? set.downJumpMaxMs : set.jumpMaxMs) * 0.001 * rate), tolerance = int(set.toleranceMs * 0.001 * rate);
        int fadeUse = fadeLength;
        if (!real) {
            if (std::fabs(need) < (down ? set.downHeldMinMs : set.heldMinMs) * 0.001 * rate) return;
            fadeUse = std::max(16, int((down ? set.downHeldFadeMs : set.heldFadeMs) * 0.001 * rate / std::max(1.0, speed)));
            fadeRead = fadeUse * speed;
        }
        if (std::fabs(need) < minJump) return;
        bool capped = std::fabs(need) > maxJump;
        if (capped) need = need > 0 ? maxJump : -maxJump;
        double last = double(hitBefore(head, 0.5 * rate));
        double amount = std::fabs(need), low, high;
        bool part = false;
        if (need < 0 && real) {  // going up, a jump must fit in the gap, or it would play the last hit twice
            double room = (target - fadeRead - guard) - (last + hold);
            if (amount > room) {
                if (room < minJump) return;
                amount = room; need = -room; part = true;
            }
        }
        if (need < 0) { low = std::max(head, last + hold + amount); high = target - fadeRead - guard; }
        else { low = std::max(head, last + hold); high = target - amount - fadeRead - guard; }
        high = std::min(high, seen - amount - fadeRead);
        if (part) high = std::min(high, low + 0.02 * rate);  // more jumps must follow in this gap, so go early
        // Going down each jump moves the head towards the hit, so a jump too big to take at once is spread through the gap.
        else if (capped && need > 0) high = std::min(high, low + 0.02 * rate);
        else if (real) low = std::max(low, high - set.lateMs * 0.001 * rate);
        if (high <= low) return;
        const int stepTime = int(0.005 * rate), length = int(set.matchMs * 0.001 * rate), lengthRough = std::max(8, length / 4);
        double best = -2; int64_t bestAt = 0; int bestJump = 0;
        for (double p = low; p <= high; p += stepTime) {
            for (int j = int(need) - tolerance; j <= int(need) + tolerance; j += 4) {
                if ((j < 0) != (need < 0) || std::abs(j) < minJump) continue;
                if (p + j < 0) continue;
                double q = likenessRough(int64_t(p), j, lengthRough) - set.offCost * std::fabs(j - need) / std::max(1, tolerance);
                if (q > best) { best = q; bestAt = int64_t(p); bestJump = j; }
            }
        }
        if (best < -1) return;
        double bestExact = -2; int exactJump = bestJump;
        for (int j = bestJump - 6; j <= bestJump + 6; j++) {
            double q = likenessExact(bestAt, j, length);
            if (q > bestExact) { bestExact = q; exactJump = j; }
        }
        planned = true; planAt = double(bestAt); planJump = exactJump; planLikeness = bestExact; planFade = fadeUse;
        planHit = real && !part && !capped ? hitAt : -1;
    }

    void pull(float *left, float *right, int frames) {
        for (int i = 0; i < frames; i++, played++) {
            if (played < tapeDelay) head = double(played) - tapeDelay;
            if (fade < 0 && waitAfterJump <= 0 && (played % 48) == 0) plan();
            if (waitAfterJump > 0) waitAfterJump--;
            float l = reader.read(ring[0].data(), mask, head), r = reader.read(ring[1].data(), mask, head);
            if (fade >= 0) {
                // Alike sounds add in step, so they fade evenly. Different sounds add as powers, so they fade by power.
                float t = std::min(1.f, float(fade) / fadeNow);
                float even = 0.5f - 0.5f * std::cos(float(M_PI) * t);
                float powerIn = std::sin(0.5f * float(M_PI) * t), powerOut = std::cos(0.5f * float(M_PI) * t);
                float gainIn = likeness * even + (1 - likeness) * powerIn, gainOut = likeness * (1 - even) + (1 - likeness) * powerOut;
                l = gainOut * l + gainIn * reader.read(ring[0].data(), mask, nextHead);
                r = gainOut * r + gainIn * reader.read(ring[1].data(), mask, nextHead);
                nextHead += speed;
                if (++fade >= fadeNow) { head = nextHead - speed; fade = -1; }
            }
            if (set.split) route.read(played - tapeDelay, speed != 1, l, r);
            left[i] = l; right[i] = r;
            head += speed;
        }
    }
};

extern "C" {

HeavyChain *heavy_new(double sampleRate, int maxFrames) {
    if (sampleRate < 8000 || maxFrames < 1) return nullptr;
    HeavyChain *chain = new HeavyChain();
    chain->rate = sampleRate;
    chain->hitStep = std::max(1, int(0.0025 * sampleRate));
    int64_t size = 1 << 16;
    while (size < int64_t(5 * sampleRate)) size *= 2;
    chain->size = size; chain->mask = size - 1;
    for (int c = 0; c < 2; c++) { chain->ring[c].assign(size, 0.f); chain->match[c].assign(size, 0.f); chain->quarter[c].assign(size / 4, 0.f); }
    chain->hits.assign(size / chain->hitStep + 1, 0);
    chain->applySettings();
    chain->finder.init(sampleRate, std::max(1, int(std::lround(sampleRate / 48000))));
    chain->limiter.init(sampleRate, chain->set.limitLookMs, chain->set.limitReleaseMs);
    chain->reader.init();
    chain->jumpLog.reserve(20000);
    chain->route.init(sampleRate, size, chain->set.cutHz);
    chain->applyDelay();
    chain->setSemis(0);
    return chain;
}

void heavy_delete(HeavyChain *chain) { delete chain; }

void heavy_set_semis(HeavyChain *chain, double semis) {
    if (semis != chain->semis) chain->setSemis(semis);
}

void heavy_process(HeavyChain *chain, const float *const *in, float *const *out, int frames) {
    chain->take(in[0], in[1], frames);
    chain->pull(out[0], out[1], frames);
    for (int i = 0; i < frames; i++) chain->limiter.run(out[0][i], out[1][i]);
}

int heavy_tune(HeavyChain *chain, const char *key, double value) {
    Settings &s = chain->set;
    std::string k = key;
    if (k == "fadems") s.fadeMs = value;
    else if (k == "jumpminms") s.jumpMinMs = value;
    else if (k == "jumpmaxms") s.jumpMaxMs = value;
    else if (k == "matchms") s.matchMs = value;
    else if (k == "tolerancems") s.toleranceMs = value;
    else if (k == "holdms") s.holdMs = value;
    else if (k == "guardms") s.guardMs = value;
    else if (k == "matchlowhz") s.matchLowHz = value;
    else if (k == "matchhighhz") s.matchHighHz = value;
    else if (k == "sensitivity") s.sensitivity = value;
    else if (k == "latems") s.lateMs = value;
    else if (k == "heldminms") s.heldMinMs = value;
    else if (k == "heldfadems") s.heldFadeMs = value;
    else if (k == "downjumpmaxms") s.downJumpMaxMs = value;
    else if (k == "downheldminms") s.downHeldMinMs = value;
    else if (k == "downheldfadems") s.downHeldFadeMs = value;
    else if (k == "split") s.split = value != 0;
    else if (k == "cuthz") { s.cutHz = value; chain->route.design(chain->rate, value); }
    else if (k == "limlookms") { s.limitLookMs = value; chain->limiter.init(chain->rate, s.limitLookMs, s.limitReleaseMs); }
    else if (k == "limreleasems") { s.limitReleaseMs = value; chain->limiter.init(chain->rate, s.limitLookMs, s.limitReleaseMs); }
    else if (k == "settlems") s.settleMs = value;
    else if (k == "settleupto") s.settleUpTo = value;
    else if (k == "offcost") s.offCost = value;
    else return 0;
    chain->applySettings();
    chain->applyDelay();
    chain->setSemis(chain->semis);
    return 1;
}

void heavy_get_info(const HeavyChain *chain, HeavyInfo *info, long long *jumpsAt, int capacity) {
    info->jumps = chain->jumps;
    info->forced = chain->forced;
    info->meanLikeness = chain->jumps ? chain->likenessSum / chain->jumps : 0;
    if (jumpsAt) for (size_t i = 0; i < chain->jumpLog.size() && int(i) < capacity; i++) jumpsAt[i] = chain->jumpLog[i];
}

int heavy_latency_frames(const HeavyChain *chain) { return chain->delay + chain->limiter.look; }

struct HeavyLimiter { Limiter limiter; };

HeavyLimiter *heavy_limiter_new(double sampleRate) {
    HeavyLimiter *l = new HeavyLimiter();
    l->limiter.init(sampleRate);
    return l;
}

void heavy_limiter_delete(HeavyLimiter *limiter) { delete limiter; }

void heavy_limiter_process(HeavyLimiter *limiter, float *left, float *right, int frames) {
    for (int i = 0; i < frames; i++) limiter->limiter.run(left[i], right[i]);
}

void heavy_limiter_reset(HeavyLimiter *limiter) { limiter->limiter.reset(); }

int heavy_limiter_latency_frames(const HeavyLimiter *limiter) { return limiter->limiter.look; }

}
