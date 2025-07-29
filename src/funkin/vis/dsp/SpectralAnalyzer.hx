package funkin.vis.dsp;

import flixel.FlxG;
import flixel.math.FlxMath;
import funkin.vis._internal.html5.AnalyzerNode;
import funkin.vis.audioclip.frontends.LimeAudioClip;
import grig.audio.FFT;
import grig.audio.FFTVisualization;
import lime.media.AudioSource;

using grig.audio.lime.UInt8ArrayTools;

typedef Bar = {
    var value:Float;
    var peak:Float;
}

typedef BarObject = {
    var binLo:Int;
    var binHi:Int;
    var freqLo:Float;
    var freqHi:Float;
    var recentValues:RecentPeakFinder;
}

enum MathType {
    Round;
    Floor;
    Ceil;
    Cast;
}

class SpectralAnalyzer {
    public var minDb(default, set):Float = -70;
    public var maxDb(default, set):Float = -20;
    public var fftN(default, set):Int = 4096;
    public var minFreq:Float = 20;
    public var maxFreq:Float = 22000;

    var audioSource:AudioSource;
    var audioClip:AudioClip;
    private var barCount:Int;
    private var maxDelta:Float;
    private var peakHold:Int;
    var fftN2:Int = 2048;
    #if web
    private var htmlAnalyzer:AnalyzerNode;
    private var bars:Array<BarObject> = [];
    #else
    private var fft:FFT;
    private var vis = new FFTVisualization();
    private var barHistories = new Array<RecentPeakFinder>();
    private var blackmanWindow = new Array<Float>();
    #end

    private static inline var LN10:Float = 2.302585092994046;

    public function changeSnd(audioSource:AudioSource) {
        this.audioSource = audioSource;
        this.audioClip = new LimeAudioClip(audioSource);
    }

    private function freqToBin(freq:Float, mathType:MathType = Round):Int {
        var bin = freq * fftN2 / audioClip.audioBuffer.sampleRate;
        return switch (mathType) {
            case Round: Math.round(bin);
            case Floor: Math.floor(bin);
            case Ceil: Math.ceil(bin);
            case Cast: Std.int(bin);
        }
    }

    function normalizedB(value:Float) {
        var maxValue = maxDb;
        var minValue = minDb;
        return clamp((value - minValue) / (maxValue - minValue), 0, 1);
    }

    function calcBars(barCount:Int, peakHold:Int) {
        #if web
        bars = [];
        var logStep = (LogHelper.log10(maxFreq) - LogHelper.log10(minFreq)) / (barCount);

        var scaleMin:Float = Scaling.freqScaleLog(minFreq);
        var scaleMax:Float = Scaling.freqScaleLog(maxFreq);

        var curScale:Float = scaleMin;

        for (i in 0...barCount) {
            var curFreq:Float = Math.pow(10, LogHelper.log10(minFreq) + (logStep * i));

            var freqLo:Float = curFreq;
            var freqHi:Float = Math.pow(10, LogHelper.log10(minFreq) + (logStep * (i + 1)));

            var binLo = freqToBin(freqLo, Floor);
            var binHi = freqToBin(freqHi);

            bars.push({
                binLo: binLo,
                binHi: binHi,
                freqLo: freqLo,
                freqHi: freqHi,
                recentValues: new RecentPeakFinder(peakHold)
            });
        }

        if (bars[0].freqLo < minFreq) {
            bars[0].freqLo = minFreq;
            bars[0].binLo = freqToBin(minFreq, Floor);
        }

        if (bars[bars.length - 1].freqHi > maxFreq) {
            bars[bars.length - 1].freqHi = maxFreq;
            bars[bars.length - 1].binHi = freqToBin(maxFreq, Floor);
        }
        #else
        if (barCount > barHistories.length) {
            barHistories.resize(barCount);
        }
        for (i in 0...barCount) {
            if (barHistories[i] == null)
                barHistories[i] = new RecentPeakFinder();
        }
        #end
    }

    function resizeBlackmanWindow(size:Int) {
        #if !web
        if (blackmanWindow.length == size)
            return;
        blackmanWindow.resize(size);
        for (i in 0...size) {
            blackmanWindow[i] = calculateBlackmanWindow(i, size);
        }
        #end
    }

    public function new(audioSource:AudioSource, barCount:Int, maxDelta:Float = 0.01, peakHold:Int = 30) {
        this.audioSource = audioSource;
        this.audioClip = new LimeAudioClip(audioSource);
        this.barCount = barCount;
        this.maxDelta = maxDelta;
        this.peakHold = peakHold;

        #if web
        htmlAnalyzer = new AnalyzerNode(audioClip);
        #else
        fft = new FFT(fftN);
        #end

        calcBars(barCount, peakHold);
        resizeBlackmanWindow(fftN);
    }
    
    public function getLevels(?levels:Array<Bar>):Array<Bar> {
        if (levels == null)
            levels = new Array<Bar>();
        #if web
        var amplitudes:Array<Float> = htmlAnalyzer.getFloatFrequencyData();
        var levels = new Array<Bar>();
    
        for (i in 0...bars.length) {
            var bar = bars[i];
            var binLo = bar.binLo;
            var binHi = bar.binHi;
    
            var value:Float = minDb;
            for (j in (binLo + 1)...(binHi)) {
                value = Math.max(value, amplitudes[Std.int(j)]);
            }
    
            // 严格限定只响应60-150Hz底鼓频段
            var freqCenter = Math.sqrt(bar.freqLo * bar.freqHi);
            if (freqCenter >= 60 && freqCenter <= 150) {
                value += 20; // 强烈提升底鼓频段
            } else {
                value -= 30; // 其他频率大幅压制
            }
    
            value = normalizedB(value);
            bar.recentValues.push(value);
            levels.push({value: value, peak: bar.recentValues.peak});
        }
        #else
        // 非Web平台实现
        var freqs = fft.calcFreq(signal);
        var bars = vis.makeLogGraph(freqs, barCount + 1, Math.floor(maxDb - minDb), 16);
    
        levels.resize(bars.length - 1);
        for (i in 0...bars.length - 1) {
            var frequency = minFreq * Math.pow(10, (Math.log(maxFreq / minFreq) / LN10 * (i / barCount)));
            var value = bars[i] / 16;
    
            if (frequency >= 60 && frequency <= 150) {
                value *= 3.0;
            } else {
                value *= 0.1;
            }
    
            barHistories[i].push(value);
            levels[i] = {
                value: value, 
                peak: barHistories[i].peak
            };
        }
        #end
        return levels;
    }

    var _buffer:Array<Float> = [];

    function getSignal(data:lime.utils.UInt8Array, bitsPerSample:Int):Array<Float> {
        switch (bitsPerSample) {
            case 8:
                _buffer.resize(data.length);
                for (i in 0...data.length)
                    _buffer[i] = data[i] / 128.0;

            case 16:
                _buffer.resize(Std.int(data.length / 2));
                for (i in 0..._buffer.length)
                    _buffer[i] = data.getInt16(i * 2) / 32767.0;

            case 24:
                _buffer.resize(Std.int(data.length / 3));
                for (i in 0..._buffer.length)
                    _buffer[i] = data.getInt24(i * 3) / 8388607.0;

            case 32:
                _buffer.resize(Std.int(data.length / 4));
                for (i in 0..._buffer.length)
                    _buffer[i] = data.getInt32(i * 4) / 2147483647.0;

            default:
                trace('Unknown integer audio format');
        }
        return _buffer;
    }

    @:generic
    static inline function clamp<T:Float>(val:T, min:T, max:T):T {
        return val <= min ? min : val >= max ? max : val;
    }

    static function calculateBlackmanWindow(n:Int, fftN:Int) {
        return 0.42 - 0.50 * Math.cos(2 * Math.PI * n / (fftN - 1)) + 0.08 * Math.cos(4 * Math.PI * n / (fftN - 1));
    }

    @:generic
    static public inline function min<T:Float>(x:T, y:T):T {
        return x > y ? y : x;
    }

    function set_minDb(value:Float):Float {
        minDb = value;
        #if web
        htmlAnalyzer.minDecibels = value;
        #end
        return value;
    }

    function set_maxDb(value:Float):Float {
        maxDb = value;
        #if web
        htmlAnalyzer.maxDecibels = value;
        #end
        return value;
    }

    function set_fftN(value:Int):Int {
        fftN = value;
        var pow2 = FFT.nextPow2(value);
        fftN2 = Std.int(pow2 / 2);
        #if web
        htmlAnalyzer.fftSize = pow2;
        #else
        fft = new FFT(value);
        #end
        calcBars(barCount, peakHold);
        resizeBlackmanWindow(fftN);
        return pow2;
    }
}
