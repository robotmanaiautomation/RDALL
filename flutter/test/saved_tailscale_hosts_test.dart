import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/mobile/widgets/saved_tailscale_hosts.dart';

void main() {
  testWidgets('saved Mac survives reopening and connects using its address',
      (tester) async {
    var stored = '';
    final connections = <String>[];
    Widget page() => MaterialApp(
            home: Scaffold(
                body: SavedTailscaleHosts(
          readHosts: () => stored,
          writeHosts: (value) async => stored = value,
          onConnect: connections.add,
          initialAddress: () => '100.90.80.70',
        )));

    await tester.pumpWidget(page());
    await tester.tap(find.byKey(const ValueKey('rdall-tailscale-add')));
    await tester.pumpAndSettle();
    expect(find.text('100.90.80.70'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('rdall-tailscale-name')), 'My Mac');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(jsonDecode(stored), [
      {'name': 'My Mac', 'address': '100.90.80.70:21118'}
    ]);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    expect(find.text('My Mac'), findsOneWidget);
    await tester.tap(find.text('My Mac'));
    expect(connections, ['100.90.80.70:21118']);
  });

  testWidgets('MagicDNS device can be edited and deleted persistently',
      (tester) async {
    var stored = '[{"name":"Mac","address":"mac.tailnet.ts.net:21118"}]';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SavedTailscaleHosts(
      readHosts: () => stored,
      writeHosts: (value) async => stored = value,
      onConnect: (_) {},
      initialAddress: () => '',
    ))));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('rdall-tailscale-name')), 'Studio');
    await tester.enterText(
        find.byKey(const ValueKey('rdall-tailscale-address')),
        '  STUDIO.TAILNET.TS.NET:22222  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Studio'), findsOneWidget);
    expect(jsonDecode(stored), [
      {'name': 'Studio', 'address': 'studio.tailnet.ts.net:22222'}
    ]);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Studio'), findsNothing);
    expect(jsonDecode(stored), isEmpty);
  });

  testWidgets('invalid and duplicate addresses are not saved', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const original = '[{"name":"Mac","address":"100.90.80.70:21118"}]';
    var stored = original;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SavedTailscaleHosts(
      readHosts: () => stored,
      writeHosts: (value) async => stored = value,
      onConnect: (_) {},
      initialAddress: () => '',
    ))));
    await tester.tap(find.byKey(const ValueKey('rdall-tailscale-add')));
    await tester.pumpAndSettle();
    for (final address in ['100.90.80.70:65536', '999.1.2.3', 'my-mac']) {
      await tester.enterText(
          find.byKey(const ValueKey('rdall-tailscale-address')), address);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid IPv4 or full hostname and port.'),
          findsOneWidget);
      expect(stored, original);
    }
    await tester.enterText(
        find.byKey(const ValueKey('rdall-tailscale-address')), '100.90.80.70');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('This address is already saved.'), findsOneWidget);
    expect(stored, original);
  });
}
