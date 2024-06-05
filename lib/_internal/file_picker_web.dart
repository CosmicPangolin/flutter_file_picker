import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'package:web/web.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class FilePickerWeb extends FilePicker {
  late Element _target;
  final String _kFilePickerInputsDomId = '__file_picker_web-file-input';

  final int _readStreamChunkSize = 1000 * 1000; // 1 MB

  static final FilePickerWeb platform = FilePickerWeb._();

  FilePickerWeb._() {
    _target = _ensureInitialized(_kFilePickerInputsDomId);
  }

  static void registerWith(Registrar registrar) {
    FilePicker.platform = platform;
  }

  /// Initializes a DOM container where we can host input elements.
  Element _ensureInitialized(String id) {
    Element? target = document.querySelector('#$id');
    if (target == null) {
      final Element targetElement = document.createElement(
        'flt-file-picker-inputs',
      )..id = id;

      document.querySelector('body')!.children.add(targetElement);
      target = targetElement;
    }
    return target;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    bool withData = true,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    int compressionQuality = 20,
  }) async {
    if (type != FileType.custom && (allowedExtensions?.isNotEmpty ?? false)) {
      throw Exception(
          'You are setting a type [$type]. Custom extension filters are only allowed with FileType.custom, please change it or remove filters.');
    }

    final Completer<List<PlatformFile>?> filesCompleter = Completer<List<PlatformFile>?>();

    String accept = _fileType(type, allowedExtensions);
    HTMLInputElement uploadInput = HTMLInputElement();
    uploadInput.type = 'file';
    uploadInput.draggable = true;
    uploadInput.multiple = allowMultiple;
    uploadInput.accept = accept;
    uploadInput.style.display = 'none';

    bool changeEventTriggered = false;

    if (onFileLoading != null) {
      onFileLoading(FilePickerStatus.picking);
    }

    void changeEventListener(Event e) async {
      if (changeEventTriggered) {
        return;
      }
      changeEventTriggered = true;

      final FileList files = uploadInput.files!;
      final List<PlatformFile> pickedFiles = [];

      void addPickedFile(
        File file,
        Uint8List? bytes,
        String? path,
        Stream<List<int>>? readStream,
      ) {
        pickedFiles.add(PlatformFile(
          name: file.name,
          path: path,
          size: bytes != null ? bytes.length : file.size,
          bytes: bytes,
          readStream: readStream,
        ));

        if (pickedFiles.length >= files.length) {
          if (onFileLoading != null) {
            onFileLoading(FilePickerStatus.done);
          }
          filesCompleter.complete(pickedFiles);
        }
      }

      for (int i = 0; i < files.length; i++) {
        final File? file = files.item(i);
        if (file == null) {
          continue;
        }

        if (withReadStream) {
          addPickedFile(file, null, null, _openFileReadStream(file));
          continue;
        }

        if (!withData) {
          final FileReader reader = FileReader();
          reader.onLoadEnd.listen((e) {
            String? result = (reader.result as JSString?)?.toDart;
            addPickedFile(file, null, result, null);
          });
          reader.readAsDataURL(file);
          continue;
        }

        final syncCompleter = Completer<void>();
        final FileReader reader = FileReader();
        reader.onLoadEnd.listen((e) {
          ByteBuffer? byteBuffer = (reader.result as JSArrayBuffer?)?.toDart;
          addPickedFile(file, byteBuffer?.asUint8List(), null, null);
          syncCompleter.complete();
        });
        reader.readAsArrayBuffer(file);
        if (readSequential) {
          await syncCompleter.future;
        }
      }
    }

    void cancelledEventListener(Event _) {
      window.removeEventListener('focus', cancelledEventListener.toJS);

      // This listener is called before the input changed event,
      // and the `uploadInput.files` value is still null
      // Wait for results from js to dart
      Future.delayed(Duration(seconds: 1)).then((value) {
        if (!changeEventTriggered) {
          changeEventTriggered = true;
          filesCompleter.complete(null);
        }
      });
    }

    uploadInput.onChange.listen(changeEventListener);
    uploadInput.addEventListener('change', changeEventListener.toJS);
    uploadInput.addEventListener('cancel', cancelledEventListener.toJS);

    // Listen focus event for cancelled
    window.addEventListener('focus', cancelledEventListener.toJS);

    //Add input element to the page body
    Node? firstChild = _target.firstChild;
    while (firstChild != null) {
      _target.removeChild(firstChild);
      firstChild = _target.firstChild;
    }
    _target.children.add(uploadInput);
    uploadInput.click();

    final List<PlatformFile>? files = await filesCompleter.future;

    return files == null ? null : FilePickerResult(files);
  }

  static String _fileType(FileType type, List<String>? allowedExtensions) {
    switch (type) {
      case FileType.any:
        return '';

      case FileType.audio:
        return 'audio/*';

      case FileType.image:
        return 'image/*';

      case FileType.video:
        return 'video/*';

      case FileType.media:
        return 'video/*|image/*';

      case FileType.custom:
        return allowedExtensions!.fold('', (prev, next) => '${prev.isEmpty ? '' : '$prev,'} .$next');
    }
  }

  Stream<List<int>> _openFileReadStream(File file) {
    return BlobStream(file);
    
  //   final reader = FileReader();

  //   int start = 0;
  //   while (start < file.size) {
  //     final end = start + _readStreamChunkSize > file.size ? file.size : start + _readStreamChunkSize;
  //     final blob = file.slice(start, end);
  //     reader.readAsArrayBuffer(blob);
  //     await EventStreamProviders.loadEvent.forTarget(reader).first;
  //     final JSAny? readerResult = reader.result;
  //     if (readerResult == null) {
  //       continue;
  //     }
  //     // TODO: use `isA<JSArrayBuffer>()` when switching to Dart 3.4
  //     // Handle the ArrayBuffer type. This maps to a `ByteBuffer` in Dart.
  //     if (readerResult.instanceOfString('ArrayBuffer')) {
  //       yield (readerResult as JSArrayBuffer).toDart.asUint8List();
  //       start += _readStreamChunkSize;
  //       continue;
  //     }
  //     // TODO: use `isA<JSArray>()` when switching to Dart 3.4
  //     // Handle the Array type.
  //     if (readerResult.instanceOfString('Array')) {
  //       // Assume this is a List<int>.
  //       yield (readerResult as JSArray).toDart.cast<int>();
  //       start += _readStreamChunkSize;
  //     }
  //   }
  }
}

// Hot-mess adapted from from https://github.com/flutter/packages/pull/5158/commits/676e98263713915c5fc8111202ddef41fe9eaf45
// How is this not solved in 2024

const int MAX_CHUNK_SIZE = 25 * 1024 * 1024;

/// This class streams an [Blob] in chunks of [MAX_CHUNK_SIZE] bytes.
class BlobStream extends Stream<Uint8List> {
  /// Constructs the byte stream.
  ///
  /// If passed, [start] will be used as the first byte to read, and [end]
  /// will be the last. If not set, the [blob] will be read in its entirety.
  BlobStream(blob, [int? start, int? end])
      : _blob = blob,
        _nextByte = start ?? 0,
        _finalByte = end;

  // The source of data that we want to Stream
  final Blob _blob;

  // The byte that will be read next.
  int _nextByte;
  // The last byte that will be read (if passed).
  final int? _finalByte;

  // The StreamController that underpins this class.
  late StreamController<Uint8List> _controller;

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    _controller = StreamController<Uint8List>(
      onListen: _readChunk,
    );
    return _controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  // Reads [_blockSize] bytes from [_currentPosition] from [_blob].
  Future<void> _readChunk() async {
    final int chunkSize = _getNextChunkSize(_nextByte, end: _finalByte);
    assert(chunkSize >= 0);

    return Future.value(_blob)
        .then((Blob blob) => blob.slice(_nextByte, _nextByte + chunkSize))
        .then(blobToByteBuffer)
        .then(_broadcastBytes)
        .then((int bytes) {
      // Computes if the blob has been fully read.
      // Move the internal [_nextByte] pointer by [bytes].
      _nextByte += bytes;
      // The blob is fully read when _nextByte is _finalByte, or
      // when readBytes is smaller than CHUNK_SIZE.
      return (bytes < MAX_CHUNK_SIZE) || (_nextByte == _finalByte);
    }).then((bool done) => !done ? _readChunk() : _doneReading());
  }

  // Sends the bytes through the stream, and returns how many bytes were sent.
  int _broadcastBytes(Uint8List bytes) {
    _controller.add(bytes);
    return bytes.lengthInBytes;
  }

  // Cleanup when the stream is done.
  Future<void> _doneReading() {
    return _controller.close();
  }

  // Returns the size in bytes of the next chunk.
  //
  // When [end] is not passed, this always returns [max] (which defaults to
  // [CHUNK_SIZE]).
  //
  // When `end` **is** passed, this returns either the remaining
  // bytes to read (`end - start`), or `max`, whatever is **smaller**.
  int _getNextChunkSize(int start, {int max = MAX_CHUNK_SIZE, int? end}) {
    return (end == null) ? max : min(max, end - start);
  }
}

/// Converts an html [Blob] object to a [Uint8List], through a [FileReader].
Future<Uint8List> blobToByteBuffer(Blob blob) async {
  final FileReader reader = FileReader();
  reader.readAsArrayBuffer(blob);

  await reader.onLoadEnd.first;

  final Uint8List? result = reader.result as Uint8List?;

  if (result == null) {
    throw Exception('Cannot read bytes from Blob. Is it still available?');
  }

  return result;
}
