import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PianoApp());
}

class PianoApp extends StatelessWidget {
  const PianoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Piano Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const PianoHome(),
    );
  }
}

// ============================================================
// Data model for a single note event
// ============================================================
class NoteEvent {
  final int midi;         // MIDI note number 21..108
  final double startSec;  // when it starts
  final double durationSec;
  NoteEvent({
    required this.midi,
    required this.startSec,
    required this.durationSec,
  });
}

// ============================================================
// Analyzer: takes raw PCM float samples and produces NoteEvents.
// Simple autocorrelation-based pitch detection on short frames.
// ============================================================
class PianoAnalyzer {
  static const int sampleRate = 22050;
  static const int frameSize = 2048;
  static const int hopSize = 512;
  static const double minFreq = 55.0;   // A1
  static const double maxFreq = 2000.0; // ~B6

  /// Convert a 16-bit signed PCM mono buffer to float.
  static Float32List pcm16ToFloat(Uint8List bytes) {
    final int n = bytes.length ~/ 2;
    final out = Float32List(n);
    for (int i = 0; i < n; i++) {
      final int lo = bytes[i * 2];
      final int hi = bytes[i * 2 + 1];
      int v = (hi << 8) | lo;
      if (v >= 0x8000) v -= 0x10000;
      out[i] = v / 32768.0;
    }
    return out;
  }

  /// Estimate fundamental frequency via autocorrelation.
  static double _detectPitch(Float32List frame) {
    final int n = frame.length;
    // remove DC
    double mean = 0;
    for (int i = 0; i < n; i++) mean += frame[i];
    mean /= n;
    final Float32List x = Float32List(n);
    for (int i = 0; i < n; i++) x[i] = frame[i] - mean;

    // RMS gate
    double rms = 0;
    for (int i = 0; i < n; i++) rms += x[i] * x[i];
    rms = math.sqrt(rms / n);
    if (rms < 0.01) return -1.0;

    final int minLag = (sampleRate / maxFreq).floor();
    final int maxLag = (sampleRate / minFreq).ceil();
    if (maxLag >= n) return -1.0;

    double bestCorr = 0;
    int bestLag = -1;
    for (int lag = minLag; lag <= maxLag; lag++) {
      double sum = 0;
      for (int i = 0; i < n - lag; i++) {
        sum += x[i] * x[i + lag];
      }
      sum /= (n - lag);
      if (sum > bestCorr) {
        bestCorr = sum;
        bestLag = lag;
      }
    }
    if (bestLag <= 0 || bestCorr < 0.05) return -1.0;
    return sampleRate / bestLag;
  }

  static int _freqToMidi(double freq) {
    if (freq <= 0) return -1;
    final double n = 69 + 12 * (math.log(freq / 440.0) / math.ln2);
    final int m = n.round();
    if (m < 21 || m > 108) return -1;
    return m;
  }

  /// Extract note events from mono float samples.
  static List<NoteEvent> analyze(Float32List samples) {
    final List<NoteEvent> out = <NoteEvent>[];
    final int total = samples.length;
    int i = 0;
    int? currentMidi;
    double currentStart = 0;
    double lastTime = 0;

    while (i + frameSize < total) {
      final Float32List frame = Float32List.sublistView(samples, i, i + frameSize);
      final double freq = _detectPitch(frame);
      final int midi = _freqToMidi(freq);
      final double t = i / sampleRate;

      if (midi != currentMidi) {
        if (currentMidi != null && currentMidi > 0) {
          final double dur = t - currentStart;
          if (dur >= 0.08) {
            out.add(NoteEvent(
              midi: currentMidi,
              startSec: currentStart,
              durationSec: dur,
            ));
          }
        }
        currentMidi = midi > 0 ? midi : null;
        currentStart = t;
      }
      lastTime = t;
      i += hopSize;
    }
    if (currentMidi != null && currentMidi > 0) {
      final double dur = lastTime - currentStart;
      if (dur >= 0.08) {
        out.add(NoteEvent(
          midi: currentMidi,
          startSec: currentStart,
          durationSec: dur,
        ));
      }
    }

    // Merge adjacent same-midi events within 60ms gap
    final List<NoteEvent> merged = <NoteEvent>[];
    for (final NoteEvent e in out) {
      if (merged.isNotEmpty) {
        final NoteEvent prev = merged.last;
        if (prev.midi == e.midi &&
            (e.startSec - (prev.startSec + prev.durationSec)) < 0.06) {
          merged[merged.length - 1] = NoteEvent(
            midi: prev.midi,
            startSec: prev.startSec,
            durationSec: (e.startSec + e.durationSec) - prev.startSec,
          );
          continue;
        }
      }
      merged.add(e);
    }
    return merged;
  }

  /// Very small WAV (PCM 16-bit mono) parser. Returns float samples.
  static Float32List parseWav(Uint8List bytes) {
    if (bytes.length < 44) return Float32List(0);
    final ByteData bd = ByteData.sublistView(bytes);
    // RIFF check
    if (bytes[0] != 0x52 || bytes[1] != 0x49 ||
        bytes[2] != 0x46 || bytes[3] != 0x46) {
      return Float32List(0);
    }
    // find 'data' chunk
    int offset = 12;
    int dataStart = -1;
    int dataLen = 0;
    int channels = 1;
    int bitsPerSample = 16;
    int sampleRateFile = sampleRate;
    while (offset + 8 <= bytes.length) {
      final int id0 = bytes[offset];
      final int id1 = bytes[offset + 1];
      final int id2 = bytes[offset + 2];
      final int id3 = bytes[offset + 3];
      final int chunkSize = bd.getUint32(offset + 4, Endian.little);
      if (id0 == 0x66 && id1 == 0x6D && id2 == 0x74 && id3 == 0x20) {
        channels = bd.getUint16(offset + 10, Endian.little);
        sampleRateFile = bd.getUint32(offset + 12, Endian.little);
        bitsPerSample = bd.getUint16(offset + 22, Endian.little);
      } else if (id0 == 0x64 && id1 == 0x61 && id2 == 0x74 && id3 == 0x61) {
        dataStart = offset + 8;
        dataLen = chunkSize;
        break;
      }
      offset += 8 + chunkSize + (chunkSize & 1);
    }
    if (dataStart < 0) return Float32List(0);
    if (dataStart + dataLen > bytes.length) {
      dataLen = bytes.length - dataStart;
    }

    // Downsample to target sampleRate if needed (linear)
    if (bitsPerSample == 16) {
      final Uint8List data = Uint8List.sublistView(
          bytes, dataStart, dataStart + dataLen);
      Float32List mono = pcm16ToFloat(data);
      if (channels == 2) {
        final int m = mono.length ~/ 2;
        final Float32List m2 = Float32List(m);
        for (int i = 0; i < m; i++) {
          m2[i] = (mono[i * 2] + mono[i * 2 + 1]) * 0.5;
        }
        mono = m2;
      }
      if (sampleRateFile != sampleRate && sampleRateFile > 0) {
        final double ratio = sampleRateFile / sampleRate;
        final int outLen = (mono.length / ratio).floor();
        final Float32List resampled = Float32List(outLen);
        for (int i = 0; i < outLen; i++) {
          final double src = i * ratio;
          final int i0 = src.floor();
          final int i1 = math.min(i0 + 1, mono.length - 1);
          final double frac = src - i0;
          resampled[i] = mono[i0] * (1 - frac) + mono[i1] * frac;
        }
        return resampled;
      }
      return mono;
    }
    return Float32List(0);
  }
}

// ============================================================
// Piano keyboard widget: 7 octaves (MIDI 21..108), 88 keys.
// ============================================================
class PianoKeyboard extends StatelessWidget {
  final Set<int> activeMidi;
  final double keyHeight;
  const PianoKeyboard({
    super.key,
    required this.activeMidi,
    this.keyHeight = 160,
  });

  static const List<int> _whitePc = <int>[0, 2, 4, 5, 7, 9, 11];

  bool _isWhite(int midi) => _whitePc.contains(midi % 12);

  @override
  Widget build(BuildContext context) {
    final List<int> midis = List<int>.generate(88, (i) => 21 + i);
    final List<int> whites = midis.where(_isWhite).toList();
    final double keyWidth = 28;
    final double totalWidth = whites.length * keyWidth;

    return SizedBox(
      height: keyHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          height: keyHeight,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Row(
                  children: whites.map((int m) {
                    final bool active = activeMidi.contains(m);
                    return Container(
                      width: keyWidth,
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF7E57C2)
                            : const Color(0xFFF5F5F5),
                        border: Border.all(
                          color: const Color(0xFF000000),
                          width: 1,
                        ),
                      ),
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        _midiName(m),
                        style: TextStyle(
                          fontSize: 9,
                          color: active
                              ? Colors.white
                              : const Color(0xFF333333),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              ...midis.where((int m) => !_isWhite(m)).map((int m) {
                // count whites before this black key
                final int whitesBefore =
                    whites.where((int w) => w < m).length;
                final double left = whitesBefore * keyWidth - keyWidth * 0.35;
                final bool active = activeMidi.contains(m);
                return Positioned(
                  left: left,
                  top: 0,
                  child: Container(
                    width: keyWidth * 0.7,
                    height: keyHeight * 0.62,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF4527A0)
                          : const Color(0xFF111111),
                      border: Border.all(
                        color: const Color(0xFF000000),
                        width: 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ],
          ),
        ),
      ),
    );
  }

  static String _midiName(int midi) {
    const List<String> names = <String>[
      'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'
    ];
    final int pc = midi % 12;
    final int octave = (midi ~/ 12) - 1;
    return '${names[pc]}$octave';
  }
}

// ============================================================
// Playback engine: schedules note events with a Timer.
// ============================================================
class PlaybackEngine {
  final List<NoteEvent> events;
  final void Function(Set<int> active) onUpdate;
  final VoidCallback onDone;

  Timer? _ticker;
  final Stopwatch _clock = Stopwatch();
  int _nextIndex = 0;
  final Set<int> _active = <int>{};
  final Map<int, double> _releaseAt = <int, double>{};

  PlaybackEngine({
    required this.events,
    required this.onUpdate,
    required this.onDone,
  });

  void start() {
    _clock.reset();
    _clock.start();
    _nextIndex = 0;
    _active.clear();
    _releaseAt.clear();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), _tick);
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
    _clock.stop();
    _active.clear();
    onUpdate(const <int>{});
  }

  void _tick(Timer t) {
    final double now = _clock.elapsedMicroseconds / 1e6;
    bool changed = false;

    while (_nextIndex < events.length &&
        events[_nextIndex].startSec <= now) {
      final NoteEvent e = events[_nextIndex];
      _active.add(e.midi);
      _releaseAt[e.midi] = e.startSec + e.durationSec;
      _nextIndex++;
      changed = true;
    }

    final List<int> toRemove = <int>[];
    _releaseAt.forEach((int midi, double at) {
      if (at <= now) {
        _active.remove(midi);
        toRemove.add(midi);
        changed = true;
      }
    });
    for (final int m in toRemove) {
      _releaseAt.remove(m);
    }

    if (changed) onUpdate(Set<int>.from(_active));

    if (_nextIndex >= events.length && _active.isEmpty) {
      stop();
      onDone();
    }
  }
}

// ============================================================
// Main screen
// ============================================================
class PianoHome extends StatefulWidget {
  const PianoHome({super.key});

  @override
  State<PianoHome> createState() => _PianoHomeState();
}

class _PianoHomeState extends State<PianoHome> {
  List<NoteEvent> _events = <NoteEvent>[];
  Set<int> _active = <int>{};
  PlaybackEngine? _engine;
  bool _loading = false;
  String _status = 'اختر ملف صوت (WAV) من الجهاز لبدء التحليل والعزف.';
  String? _lastPath;

  @override
  void initState() {
    super.initState();
    _loadLastPath();
  }

  @override
  void dispose() {
    _engine?.stop();
    super.dispose();
  }

  Future<void> _loadLastPath() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? p = prefs.getString('last_audio_path');
      if (p != null && mounted) {
        setState(() {
          _lastPath = p;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickFile() async {
    try {
      final PermissionStatus st =
          await Permission.audio.request();
      if (!st.isGranted && !st.isLimited) {
        final PermissionStatus st2 =
            await Permission.storage.request();
        if (!st2.isGranted) {
          if (mounted) {
            setState(() {
              _status = 'لم يتم منح صلاحية القراءة.';
            });
          }
          return;
        }
      }

      final FilePickerResult? res = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      if (res == null || res.files.isEmpty) return;
      final String? path = res.files.single.path;
      if (path == null) return;

      setState(() {
        _loading = true;
        _status = 'جارٍ قراءة الملف...';
        _lastPath = path;
      });

      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_audio_path', path);
      } catch (_) {}

      final File f = File(path);
      final Uint8List bytes = await f.readAsBytes();

      setState(() {
        _status = 'جارٍ تحليل اللحن...';
      });

      final Float32List samples = PianoAnalyzer.parseWav(bytes);
      if (samples.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _status =
                'تعذّر قراءة الملف. يدعم التطبيق حالياً صيغة WAV (PCM 16-bit).';
          });
        }
        return;
      }

      final List<NoteEvent> events =
          PianoAnalyzer.analyze(samples);

      if (!mounted) return;
      setState(() {
        _events = events;
        _loading = false;
        _status = events.isEmpty
            ? 'لم يتم اكتشاف نغمات واضحة في المقطع.'
            : 'تم استخراج ${events.length} نغمة. جاهز للعزف.';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = 'خطأ أثناء اختيار الملف: ${e.message ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = 'خطأ: $e';
      });
    }
  }

  void _play() {
    if (_events.isEmpty) return;
    _engine?.stop();
    _engine = PlaybackEngine(
      events: _events,
      onUpdate: (Set<int> a) {
        if (!mounted) return;
        setState(() {
          _active = a;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _active = <int>{};
          _status = 'انتهى العزف.';
        });
      },
    );
    _engine!.start();
    setState(() {
      _status = 'جارٍ العزف...';
    });
  }

  void _stop() {
    _engine?.stop();
    _engine = null;
    if (mounted) {
      setState(() {
        _active = <int>{};
        _status = 'تم الإيقاف.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('بيانو تلقائي'),
          backgroundColor: const Color(0xFF1F1B24),
        ),
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: const Color(0xFF1A1A1A),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _status,
                      style: const TextStyle(
                        color: Color(0xFFDDDDDD),
                        fontSize: 13,
                      ),
                    ),
                    if (_lastPath != null) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        'الملف: ${_lastPath!.split('/').last}',
                        style: const TextStyle(
                          color: Color(0xFF9E9E9E),
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _pickFile,
                        icon: _loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.library_music),
                        label: Text(_loading ? '...' : 'اختر مقطعاً'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF5E35B1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _events.isEmpty ? null : _play,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('اعزف'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop),
                      label: const Text('قف'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFB71C1C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  alignment: Alignment.center,
                  color: const Color(0xFF0E0E0E),
                  child: _events.isEmpty
                      ? const Text(
                          'لا توجد نغمات بعد.',
                          style: TextStyle(color: Color(0xFF777777)),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Text(
                              'النغمات: ${_events.length}',
                              style: const TextStyle(
                                color: Color(0xFFB39DDB),
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'النشطة الآن: ${_active.length}',
                              style: const TextStyle(
                                color: Color(0xFF9E9E9E),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              Container(
                color: const Color(0xFF000000),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: PianoKeyboard(
                  activeMidi: _active,
                  keyHeight: 170,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}