package funkin.vis.dsp;

class RecentPeakFinder
{
    private var buffer:Array<Float>;
    private var bufferIndex:Int = 0; // We circle arround to avoid reallocating
    public var peak(default, null):Float = 0;
    public var lastValue(get, never):Float;

    public function new(length:Int = 30) {
        buffer = new Array<Float>();
        buffer.resize(length);
    }

    public function push(value:Float):Void {
        var replaced = buffer[bufferIndex];
        buffer[bufferIndex] = value;
        if (value >= peak) peak = value;
        // A full scan is only required when the circular buffer overwrites
        // the value that supplied the old peak.  The former implementation
        // scanned all 30 entries for nearly every spectrum bar and sample.
        else if (replaced >= peak) peak = Signal.max(buffer);
        bufferIndex = if (bufferIndex + 1 == buffer.length) 0;
        else bufferIndex + 1;
    }

    private function get_lastValue():Float {
        return if (bufferIndex == 0) buffer[buffer.length - 1];
        else buffer[bufferIndex - 1];
    }
}
