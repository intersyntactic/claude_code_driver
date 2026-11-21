/// The Claude Code driver as a service of its own, which only the airlock's
/// user may call. It runs as its own user, so a seat's token is readable by
/// this process and no other: not the airlock, not a loop.
///
/// A caller connects to the Unix socket, writes one call as JSON and closes
/// its side:
///
///     {"signIn":"…","model":"…","systemPrompt":"…","request":"…"}
///
/// The service answers one JSON line per message and closes: any number of
/// `{"kind":"reported","progress":…}` while the reply streams, then one
/// `{"kind":"finished","outcome":…}`, the `Outcome<ModelReply>`.
/// [ClaudeCodeDriverSocket] is that caller.
///
/// Who is calling is read from the socket as the kernel reports it, never
/// from the call.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_peer_user_admission/is_peer_user_admission.dart';

final class ClaudeCodeDriverService {
  ClaudeCodeDriverService._(
    this._driver,
    this._admission,
    this._socket,
    this._server,
  );

  final AsksTheModel _driver;
  final PeerUserAdmission _admission;
  final File _socket;
  final ServerSocket _server;

  /// A whole trajectory rendered as text fits well inside this.
  static const maxCall = 16 << 20;

  /// Listens on [socket], asking the model through [driver] for the user
  /// [caller] alone, as [reader] (the running kernel's by default) reads
  /// each peer. A socket file nothing listens on is replaced.
  static Future<ClaudeCodeDriverService> start(
    AsksTheModel driver,
    UserId caller,
    File socket, {
    PeerUserReader? reader,
  }) async {
    final service = ClaudeCodeDriverService._(
      driver,
      PeerUserAdmission.only(caller, reader: reader),
      socket,
      await _bind(socket),
    );
    service._server.listen(service._serve);
    return service;
  }

  static Future<ServerSocket> _bind(File socket) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    return ServerSocket.bind(address, 0);
  }

  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
  }

  Future<void> _serve(Socket socket) async {
    try {
      if (!_admission.admits(socket)) {
        socket.destroy();
        return;
      }
      final bytes = BytesBuilder(copy: false);
      var tooLarge = false;
      await for (final chunk in socket) {
        if (bytes.length + chunk.length > maxCall) {
          tooLarge = true;
          break;
        }
        bytes.add(chunk);
      }
      if (tooLarge) {
        _write(socket, const Finished(Refused('call too large')));
        await socket.close();
        return;
      }
      final ModelSignInName signIn;
      final ModelName model;
      final String systemPrompt;
      final String request;
      try {
        (signIn, model, systemPrompt, request) = decodeModelCall(
          jsonDecode(utf8.decode(bytes.takeBytes(), allowMalformed: true)),
        );
      } on FormatException catch (e) {
        _write(socket, Finished(Refused('not a call: ${e.message}')));
        await socket.close();
        return;
      }
      final outcome = await _driver.askTheModel(
        signIn,
        model,
        systemPrompt,
        request,
        report: (progress) => _write(socket, Reported(progress)),
      );
      _write(socket, Finished(outcome));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  static void _write(Socket socket, ProgramMessage<ModelReply> message) =>
      socket.add(
        utf8.encode(
          '${jsonEncode(encodeProgramMessage(message, encodeModelReply))}\n',
        ),
      );
}

/// Looks at the driver on the other end of a connected socket, such as which
/// release the kernel says it is, before any call is written to it. Returns
/// why to refuse it, or null to go on.
typedef CheckDriver = Future<String?> Function(Socket driver);

/// [AsksTheModel] in another process: passes each call to the service at
/// [socket] and reports the reply as it streams back. Holds no secret.
final class ClaudeCodeDriverSocket implements AsksTheModel {
  /// [checkDriver] runs on every connection before the call is sent, so a
  /// driver it refuses never sees the call.
  ClaudeCodeDriverSocket(this.socket, {this.checkDriver});

  final File socket;
  final CheckDriver? checkDriver;

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      if (await checkDriver?.call(s) case final why?) {
        s.destroy();
        return Refused('claude code driver: $why');
      }
      s.add(
        utf8.encode(
          jsonEncode(encodeModelCall(signIn, model, systemPrompt, request)),
        ),
      );
      await s.close();
      await for (final line
          in utf8.decoder.bind(s).transform(const LineSplitter())) {
        switch (decodeProgramMessage(jsonDecode(line), decodeModelReply)) {
          case Reported(:final progress):
            report(progress);
          case Finished(:final outcome):
            return outcome;
        }
      }
      return const Refused('claude code driver: refused caller');
    } on SocketException catch (e) {
      return Refused('claude code driver: ${e.message}');
    } on FormatException catch (e) {
      return Refused('claude code driver: unreadable answer: ${e.message}');
    }
  }
}
