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

    // 鼓声增强参数
    private var KICK_BOOST:Float = 1.8;      // 低频增强倍数 (50-150Hz)
    private var SNARE_BOOST:Float = 1.5;     // 中频增强倍数 (1k-3kHz)
    private var HIGH_CUT:Float = 0.6;        // 高频衰减系数 (>3kHz)
    private var PEAK_HOLD_FRAMES:Int = 15;   // 鼓声峰值保持帧数

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
    private var kickPeakHolders:Array<RecentPeakFinder> = []; // 专门用于鼓声峰值保持
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
        return clamp((value - minDb) / (maxDb - minDb), 0, 1);
    }

    function calcBars(barCount:Int, peakHold:Int) {
        #if web
	bars = [];
	var logStep = (LogHelper.log10(maxFreq) - LogHelper.log10(minFreq)) / (barCount);

	var scaleMin:Float = Scaling.freqScaleLog(minFreq);
	var scaleMax:Float = Scaling.freqScaleLog(maxFreq);

	var curScale:Float = scaleMin;

	// var stride = (scaleMax - scaleMin) / bands;

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
            kickPeakHolders.resize(barCount);
        }
        
        // 重新计算频段分布（低频更密集）
        var logMin = Math.log(minFreq);
        var logMax = Math.log(maxFreq);
        var logRange = logMax - logMin;
        
        for (i in 0...barCount) {
            // 非线性分布（低频段更多）
            var t = Math.pow(i / barCount, 0.6);
            var freqCenter = Math.exp(logMin + t * logRange);
            
            if (barHistories[i] == null) {
                barHistories[i] = new RecentPeakFinder(peakHold);
                
                // 为低频段创建更快的峰值跟踪器
                if (freqCenter < 200) {
                    kickPeakHolders[i] = new RecentPeakFinder(PEAK_HOLD_FRAMES);
                }
            }
        }
        #end
    }

    function resizeBlackmanWindow(size:Int) {
        #if !web
        if (blackmanWindow.length == size) return;
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
        if (levels == null) levels = new Array<Bar>();
        
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

		if (bar.freqLo < 350 && bar.freqLo > 100) {
			value += 10;
		}
		if (bar.binHi > 2800) {
			value -= 2;
		}

		// this isn't for clamping, it's to get a value
		// between 0 and 1!
		value = normalizedB(value);
		bar.recentValues.push(value);
		var recentPeak = bar.recentValues.peak;

		if (levels[i] != null) {
			levels[i].value = value;
			levels[i].peak = recentPeak;
		} else
			levels.push({value: value, peak: recentPeak});

	}

	return levels;
        #else
        var numOctets = Std.int(audioSource.buffer.bitsPerSample / 8);
        var wantedLength = fftN * numOctets * audioSource.buffer.channels;
        var startFrame = audioClip.currentFrame;
        startFrame -= startFrame % numOctets;
        
        if (startFrame < 0) {
            return levels = [for (bar in 0...barCount) {value: 0, peak: 0}];
        }
        
        var segment = audioSource.buffer.data.subarray(
            startFrame, 
            min(startFrame + wantedLength, audioSource.buffer.data.length)
        );
        var signal = getSignal(segment, audioSource.buffer.bitsPerSample);

        // 多声道混合 + 加窗
        if (audioSource.buffer.channels > 1) {
            var mixed = new Array<Float>();
            mixed.resize(Std.int(signal.length / audioSource.buffer.channels));
            for (i in 0...mixed.length) {
                mixed[i] = 0.0;
                for (c in 0...audioSource.buffer.channels) {
                    mixed[i] += signal[i * audioSource.buffer.channels + c];
                }
                mixed[i] = mixed[i] / audioSource.buffer.channels * blackmanWindow[i];
            }
            signal = mixed;
        }

        // FFT计算
        var freqs = fft.calcFreq(signal);
        var bars = vis.makeLogGraph(freqs, barCount + 1, Math.floor(maxDb - minDb), 16);
        
        levels.resize(barCount);
        for (i in 0...barCount) {
            var freqCenter = minFreq * Math.pow(maxFreq / minFreq, i / barCount);
            var value = bars[i] / 16.0; // 归一化到0-1
            
            // 频段特异性处理
            if (freqCenter < 150) {        // Kick Drum区域
                value *= KICK_BOOST;
                if (kickPeakHolders[i] != null) {
                    kickPeakHolders[i].push(value);
                    value = kickPeakHolders[i].current;
                }
            } 
            else if (freqCenter < 1000) {  // 低频填充区域
                value *= 1.2;
            }
            else if (freqCenter < 3000) {   // Snare区域
                value *= SNARE_BOOST;
            }
            else {                          // 高频区域
                value *= HIGH_CUT;
            }

            // 限制变化速率
            var lastValue = barHistories[i].lastValue;
            if (maxDelta > 0.0) {
                value = lastValue + clamp(value - lastValue, -maxDelta, maxDelta);
            }
            
            barHistories[i].push(value);
            levels[i] = {
                value: value,
                peak: barHistories[i].peak
            };
        }
        return levels;
        #end
    }

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

    static function calculateBlackmanWindow(n:Int, fftN:Int):Float {
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
