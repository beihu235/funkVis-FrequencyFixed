package funkin.vis.dsp;

import flixel.FlxG;
import flixel.math.FlxMath;
import funkin.vis._internal.html5.AnalyzerNode;
import funkin.vis.audioclip.frontends.LimeAudioClip;
import grig.audio.FFT;
import grig.audio.FFTVisualization;
import lime.media.AudioSource;
import lime.system.System;

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
	public var minDb(default, set):Float = -80;
	public var maxDb(default, set):Float = -20;
	public var fftN(default, set):Int = 4096;
	public var minFreq:Float = 20;
	public var maxFreq:Float = 22000;
    public var preAmpGain(default, set):Float = 1.0;
    public var outputGain(default, set):Float = 1.0;
    public var eqLowHz(default, set):Float = 80;
    public var eqLowGain(default, set):Float = 0.85;
    public var eqMidLoHz(default, set):Float = 500;
    public var eqMidHiHz(default, set):Float = 2000;
    public var eqMidGain(default, set):Float = 1.15;
    public var eqHighHz(default, set):Float = 8000;
    public var eqHighGain(default, set):Float = 0.95;
    public var enableEQ(default, set):Bool = false;
	public var usePowerSpectrum(default, set):Bool = false;
    public var autoAdjustFft(default, set):Bool = false;

	// Awkwardly, we'll have to interfaces for now because there's too much platform specific stuff we need
	var audioSource:AudioSource;
	var audioClip:AudioClip;
	private var barCount:Int;
	private var maxDelta:Float;
	private var peakHold:Int;
	var fftN2:Int = 2048;
    public var updateIntervalMs(default, set):Int = 33;
    private var lastUpdateMs:Int = 0;
    private var lastLevels:Array<Bar> = [];
    private var graphScale:Array<Float> = [];
    private var graphEdges:Array<Int> = [];
    private var graphValues:Array<Int> = [];
    
    // Plan B visualization only: no adaptive scaling flag
    private inline function audioReady():Bool {
        #if web
        return audioClip != null;
        #else
        return audioSource != null && audioClip != null && audioSource.buffer != null && audioSource.buffer.data != null && audioSource.buffer.data.length > 0;
        #end
    }
	#if web
	private var htmlAnalyzer:AnalyzerNode;
	private var bars:Array<BarObject> = [];
	#else
	private var fft:FFT;
	private var vis = new FFTVisualization();
	private var barHistories = new Array<RecentPeakFinder>();
	private var blackmanWindow = new Array<Float>();
    private var mixed = new Array<Float>();
	#end

	private static inline var LN10:Float = 2.302585092994046; // Natural logarithm of 10

	public function changeSnd(audioSource:AudioSource) {
		if (audioSource == null) {
			this.audioSource = null;
			this.audioClip = null;
			return;
		}
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

	public function new(audioSource:AudioSource, barCount:Int, maxDelta:Float = 0.01, peakHold:Int = 30, ?minFreq:Float, ?maxFreq:Float) {
		this.audioSource = audioSource;
		if (audioSource != null) this.audioClip = new LimeAudioClip(audioSource); else this.audioClip = null;
		this.barCount = barCount;
		this.maxDelta = maxDelta;
		this.peakHold = peakHold;
        if (minFreq != null) this.minFreq = minFreq;
        if (maxFreq != null) this.maxFreq = maxFreq;

		#if web
		if (audioClip != null) htmlAnalyzer = new AnalyzerNode(audioClip);
		#else
		fft = new FFT(fftN);
		#end

		calcBars(barCount, peakHold);
		resizeBlackmanWindow(fftN);
	}

	public function getLevels(?levels:Array<Bar>):Array<Bar> {
		var now = System.getTimer();
		if (lastLevels != null && lastLevels.length > 0 && updateIntervalMs > 0) {
			if (now - lastUpdateMs < updateIntervalMs) {
				return lastLevels;
			}
		}
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
		if (!audioReady()) {
			levels.resize(barCount);
			for (i in 0...barCount) {
				levels[i] = { value: 0.0, peak: 0.0 };
			}
			lastLevels = levels;
			lastUpdateMs = now;
			return levels;
		}
		var numOctets = Std.int(audioSource.buffer.bitsPerSample / 8);
		var wantedLength = fftN * numOctets * audioSource.buffer.channels;
		var startFrame = audioClip.currentFrame;
		startFrame -= startFrame % numOctets;
		var segment = audioSource.buffer.data.subarray(startFrame, min(startFrame + wantedLength, audioSource.buffer.data.length));
		var signal = getSignal(segment, audioSource.buffer.bitsPerSample);

		if (audioSource.buffer.channels > 1) {
			mixed.resize(Std.int(signal.length / audioSource.buffer.channels));
            var channels = audioSource.buffer.channels;
            
            if (channels == 2) {
                // Optimized Stereo Mixing with SIMD-friendly structure
                var len = mixed.length;
                var i = 0;
                // Manual unrolling to encourage vectorization
                while (i < len - 3) {
                    var idx = i * 2;
                    mixed[i]   = (signal[idx]   + signal[idx+1]) * 0.7 * blackmanWindow[i];
                    
                    idx = (i + 1) * 2;
                    mixed[i+1] = (signal[idx]   + signal[idx+1]) * 0.7 * blackmanWindow[i+1];
                    
                    idx = (i + 2) * 2;
                    mixed[i+2] = (signal[idx]   + signal[idx+1]) * 0.7 * blackmanWindow[i+2];
                    
                    idx = (i + 3) * 2;
                    mixed[i+3] = (signal[idx]   + signal[idx+1]) * 0.7 * blackmanWindow[i+3];
                    
                    i += 4;
                }
                while (i < len) {
                    var idx = i * 2;
                    mixed[i] = (signal[idx] + signal[idx+1]) * 0.7 * blackmanWindow[i];
                    i++;
                }
            } else {
                for (i in 0...mixed.length) {
                    mixed[i] = 0.0;
                    for (c in 0...channels) {
                        mixed[i] += 0.7 * signal[i * channels + c];
                    }
                    mixed[i] *= blackmanWindow[i];
                }
            }
			signal = mixed;
		}

        if (preAmpGain != 1.0) {
            var len = signal.length;
            var i = 0;
            while (i < len - 3) {
                signal[i] *= preAmpGain;
                signal[i+1] *= preAmpGain;
                signal[i+2] *= preAmpGain;
                signal[i+3] *= preAmpGain;
                i += 4;
            }
            while (i < len) {
                signal[i] *= preAmpGain;
                i++;
            }
        }

		if (autoAdjustFft) {
			var neededBins = barCount + 1;
			var currentBins = Std.int(fftN / 2);
			if (currentBins < neededBins) {
				set_fftN(neededBins * 2);
			}
			var sr = audioClip != null && audioClip.audioBuffer != null ? audioClip.audioBuffer.sampleRate : 44100;
			var rangeBins = Std.int(((maxFreq - minFreq) * fftN2) / sr);
			if (rangeBins < neededBins && (maxFreq > minFreq)) {
				var newN2 = Std.int(Math.ceil((neededBins * sr) / (maxFreq - minFreq)));
				var newN = newN2 * 2;
				set_fftN(newN);
			}
		}

		var range = 12;
		var dbRangeAdj:Int = Std.int(Math.floor(maxDb - minDb));
		if (usePowerSpectrum) dbRangeAdj = dbRangeAdj * 2;
		var freqs:Array<Float> = usePowerSpectrum && Reflect.hasField(fft, "calcFreqPower")
			? cast Reflect.callMethod(fft, Reflect.field(fft, "calcFreqPower"), [signal])
			: fft.calcFreq(signal);
		var startBin = freqToBin(minFreq, Floor);
		var endBin = freqToBin(maxFreq, Floor);
		startBin = startBin < 0 ? 0 : startBin;
		endBin = endBin >= freqs.length ? freqs.length - 1 : endBin;
		if (endBin <= startBin) endBin = startBin + 1 < freqs.length ? startBin + 1 : startBin;
        var bars:Array<Int> = makeLogGraphRangeGlobalScale(freqs, startBin, endBin, barCount + 1, dbRangeAdj, range, usePowerSpectrum);

		if (bars.length - 1 > barHistories.length) {
			barHistories.resize(bars.length - 1);
		}

		levels.resize(bars.length - 1);
		for (i in 0...bars.length - 1) {
			if (barHistories[i] == null)
				barHistories[i] = new RecentPeakFinder();
			var recentValues = barHistories[i];
			var value = bars[i] / range;

			var frequency = minFreq * Math.pow(10, (Math.log(maxFreq / minFreq) / LN10 * (i / barCount)));
			//trace(i +'text ' + frequency)

            if (enableEQ) {
                if (frequency < eqLowHz) {
                    value *= eqLowGain;
                } else if (frequency >= eqMidLoHz && frequency <= eqMidHiHz) {
                    value *= eqMidGain;
                } else if (frequency >= eqHighHz) {
                    value *= eqHighGain;
                }
                value *= outputGain;
            }

            if (frequency < eqLowHz) {
                value *= eqLowGain;
            } else if (frequency >= eqMidLoHz && frequency <= eqMidHiHz) {
                value *= eqMidGain;
            } else if (frequency >= eqHighHz) {
                value *= eqHighGain;
            }
            value *= outputGain;

			// slew limiting
			var lastValue = recentValues.lastValue;
			if (maxDelta > 0.0) {
				var delta = clamp(value - lastValue, -1 * maxDelta, maxDelta);
				value = lastValue + delta;
			}
			recentValues.push(value);

			var recentPeak = recentValues.peak;

			if (levels[i] != null) {
				levels[i].value = value;
				levels[i].peak = recentPeak;
			} else
				levels[i] = {value: value, peak: recentPeak};
		}
		lastLevels = levels;
		lastUpdateMs = now;
		return levels;
		#end
	}

	// Prevents a memory leak by reusing array
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

    private function makeLogGraphRangeGlobalScale(freq:Array<Float>, startBin:Int, endBin:Int, bands:Int, dbRange:Int, intRange:Int, usePower:Bool):Array<Int> {
        if (startBin < 0) startBin = 0;
        if (endBin >= freq.length) endBin = freq.length - 1;
        if (endBin < startBin) endBin = startBin;
        var baseFull = freq.length;
        var xscale = graphScale;
        xscale.resize(bands + 1);
        xscale[bands] = baseFull - 0.5;
        for (i in 0...bands) {
            var scaled = (Math.pow(256, i / bands) - 0.5) * (baseFull / 256.0);
            xscale[i] = scaled;
        }
        // build integer edges monotonically increasing to avoid duplicate first bins
        var edges = graphEdges;
        edges.resize(bands + 1);
        edges[0] = startBin;
        edges[bands] = endBin;
        for (i in 1...bands) {
            var ei = Std.int(Math.round(xscale[i]));
            if (ei < startBin) ei = startBin;
            if (ei > endBin) ei = endBin;
            if (ei <= edges[i - 1]) ei = edges[i - 1] + 1;
            var remaining = (endBin - ei);
            var barsLeft = (bands - i);
            if (remaining < barsLeft) ei = endBin - barsLeft; // ensure space for remaining bars
            edges[i] = ei;
        }
        var graph = graphValues;
        graph.resize(bands);
        for (i in 0...bands) {
            var a = edges[i];
            var b = edges[i + 1];
            if (a < startBin) a = startBin;
            if (b < startBin) b = startBin;
            if (a > endBin) a = endBin;
            if (b > endBin) b = endBin;
            if (b <= a) b = a + 1 <= endBin ? a + 1 : a;
            var m = usePower ? 10 : 20;
            var maxDb:Float = -dbRange;
            for (k in a...b) {
                var amp = freq[k];
                if (amp <= 0) amp = 1e-12;
                var d:Float = m * FFT.log(10, amp);
                if (d > maxDb) maxDb = d;
            }
            var val:Float = (1 + (maxDb / dbRange)) * intRange;
            graph[i] = FFT.clamp(Std.int(val), 0, intRange);
        }
        return graph;
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
		var pow2 = FFT.nextPow2(value);
		fftN = pow2;
		fftN2 = Std.int(pow2 / 2);

		#if web
		htmlAnalyzer.fftSize = pow2;
		#else
		fft = new FFT(pow2);
		#end

		calcBars(barCount, peakHold);
		resizeBlackmanWindow(fftN);
		usePowerSpectrum = (pow2 > 1024);
		return pow2;
	}

    function set_preAmpGain(value:Float):Float {
        preAmpGain = value;
        return value;
    }

    function set_outputGain(value:Float):Float { outputGain = value; return value; }
    function set_eqLowHz(value:Float):Float { eqLowHz = value; return value; }
    function set_eqLowGain(value:Float):Float { eqLowGain = value; return value; }
    function set_eqMidLoHz(value:Float):Float { eqMidLoHz = value; return value; }
    function set_eqMidHiHz(value:Float):Float { eqMidHiHz = value; return value; }
    function set_eqMidGain(value:Float):Float { eqMidGain = value; return value; }
    function set_eqHighHz(value:Float):Float { eqHighHz = value; return value; }
    function set_eqHighGain(value:Float):Float { eqHighGain = value; return value; }
    function set_enableEQ(value:Bool):Bool { enableEQ = value; return value; }



    function set_usePowerSpectrum(value:Bool):Bool {
        usePowerSpectrum = value;
        return value;
    }

    function set_autoAdjustFft(value:Bool):Bool {
        autoAdjustFft = value;
        return value;
    }

	function set_updateIntervalMs(value:Int):Int {
		updateIntervalMs = value;
		return value;
	}
}
