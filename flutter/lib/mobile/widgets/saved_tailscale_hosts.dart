import 'dart:convert';

import 'package:flutter/material.dart';

const kRdallSavedTailscaleHosts = 'rdall-saved-tailscale-hosts';

String _text(BuildContext context, String english, String korean) =>
    Localizations.localeOf(context).languageCode == 'ko' ? korean : english;

String? _normalizeAddress(String input) {
  final parts = input.trim().toLowerCase().split(':');
  if (parts.length > 2) return null;
  final host = parts.first;
  final portText = parts.length == 2 ? parts.last : '21118';
  if (!RegExp(r'^\d{1,5}$').hasMatch(portText)) return null;
  final port = int.parse(portText);
  if (port < 1 || port > 65535) return null;

  final octets = host.split('.');
  if (octets.length == 4 &&
      octets.every((part) => RegExp(r'^\d{1,3}$').hasMatch(part))) {
    final values = octets.map(int.parse).toList();
    if (values.any((value) => value > 255)) return null;
    return '${values.join('.')}:$port';
  }
  // Match the full hostname form recognized by RustDesk's direct-connect path.
  final hostname = RegExp(
      r'^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z-]{0,61}[a-z]$');
  return hostname.hasMatch(host) ? '$host:$port' : null;
}

class _SavedHost {
  final String name;
  final String address;

  const _SavedHost(this.name, this.address);

  Map<String, String> toJson() => {'name': name, 'address': address};

  static List<_SavedHost> decode(String value) {
    if (value.isEmpty) return [];
    final rows = jsonDecode(value);
    if (rows is! List) throw const FormatException('Invalid saved hosts');
    return rows.map((row) {
      if (row is! Map || row['name'] is! String || row['address'] is! String) {
        throw const FormatException('Invalid saved host');
      }
      final address = _normalizeAddress(row['address'] as String);
      if (address == null) throw const FormatException('Invalid saved address');
      return _SavedHost(row['name'] as String, address);
    }).toList();
  }
}

class SavedTailscaleHosts extends StatefulWidget {
  final String Function() readHosts;
  final Future<void> Function(String value) writeHosts;
  final ValueChanged<String> onConnect;
  final String Function() initialAddress;

  const SavedTailscaleHosts({
    super.key,
    required this.readHosts,
    required this.writeHosts,
    required this.onConnect,
    required this.initialAddress,
  });

  @override
  State<SavedTailscaleHosts> createState() => _SavedTailscaleHostsState();
}

class _SavedTailscaleHostsState extends State<SavedTailscaleHosts> {
  List<_SavedHost> _hosts = [];
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    try {
      _hosts = _SavedHost.decode(widget.readHosts());
    } catch (_) {
      _loadFailed = true;
    }
  }

  Future<void> _persist(List<_SavedHost> hosts) async {
    setState(() => _saving = true);
    try {
      await widget
          .writeHosts(jsonEncode(hosts.map((host) => host.toJson()).toList()));
      if (mounted) setState(() => _hosts = hosts);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_text(context, 'Could not save the device list.',
              '기기 목록을 저장하지 못했습니다.')),
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([int? index]) async {
    final host = await showDialog<_SavedHost>(
      context: context,
      builder: (_) => _HostDialog(
        host: index == null ? null : _hosts[index],
        initialAddress: index == null ? widget.initialAddress() : '',
        usedAddresses: {
          for (var i = 0; i < _hosts.length; i++)
            if (i != index) _hosts[i].address,
        },
      ),
    );
    if (host == null || !mounted) return;
    final hosts = List<_SavedHost>.of(_hosts);
    if (index == null) {
      hosts.add(host);
    } else {
      hosts[index] = host;
    }
    await _persist(hosts);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          ListTile(
            title: Text(
                _text(context, 'Saved Tailscale devices', '저장한 Tailscale 기기')),
            trailing: IconButton(
              key: const ValueKey('rdall-tailscale-add'),
              tooltip: _text(context, 'Add device', '기기 추가'),
              icon: const Icon(Icons.add),
              onPressed: _saving || _loadFailed ? null : () => _edit(),
            ),
          ),
          if (_loadFailed)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_text(
                  context,
                  'Could not read the saved device list.',
                  '저장한 기기 목록을 읽지 못했습니다.')),
            )
          else if (_hosts.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(_text(
                  context,
                  'Save your Mac’s Tailscale IP or full MagicDNS name.',
                  '맥의 Tailscale IP 또는 전체 MagicDNS 이름을 저장하세요.')),
            ),
          for (var i = 0; i < _hosts.length; i++)
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(_hosts[i].name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_hosts[i].address,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: _saving ? null : () => widget.onConnect(_hosts[i].address),
              trailing: PopupMenuButton<String>(
                enabled: !_saving,
                onSelected: (action) {
                  if (action == 'edit') {
                    _edit(i);
                  } else {
                    _persist(List<_SavedHost>.of(_hosts)..removeAt(i));
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'edit', child: Text(_text(context, 'Edit', '수정'))),
                  PopupMenuItem(
                      value: 'delete',
                      child: Text(_text(context, 'Delete', '삭제'))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HostDialog extends StatefulWidget {
  final _SavedHost? host;
  final String initialAddress;
  final Set<String> usedAddresses;

  const _HostDialog(
      {required this.host,
      required this.initialAddress,
      required this.usedAddresses});

  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.host?.name ?? '');
  late final _address = TextEditingController(
      text: widget.host?.address ??
          (_normalizeAddress(widget.initialAddress) == null
              ? ''
              : widget.initialAddress));

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void save() {
      if (!_formKey.currentState!.validate()) return;
      final address = _normalizeAddress(_address.text)!;
      Navigator.of(context).pop(_SavedHost(
          _name.text.trim().isEmpty ? address : _name.text.trim(), address));
    }

    return AlertDialog(
      scrollable: true,
      title: Text(_text(context, 'Tailscale device', 'Tailscale 기기')),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('rdall-tailscale-name'),
              controller: _name,
              maxLength: 80,
              decoration: InputDecoration(
                  labelText:
                      _text(context, 'Device name (optional)', '기기 이름 (선택)')),
              textInputAction: TextInputAction.next,
            ),
            TextFormField(
              key: const ValueKey('rdall-tailscale-address'),
              controller: _address,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: _text(context, 'Tailscale address', 'Tailscale 주소'),
                hintText: '100.90.80.70:21118',
                helperText: _text(
                    context,
                    'IPv4 or full MagicDNS name. Default port: 21118.',
                    'IPv4 또는 전체 MagicDNS 이름. 기본 포트: 21118.'),
                helperMaxLines: 2,
                errorMaxLines: 3,
              ),
              validator: (value) {
                final address = _normalizeAddress(value ?? '');
                if (address == null) {
                  return _text(
                      context,
                      'Enter a valid IPv4 or full hostname and port.',
                      '올바른 IPv4 또는 전체 호스트 이름과 포트를 입력하세요.');
                }
                if (widget.usedAddresses.contains(address)) {
                  return _text(context, 'This address is already saved.',
                      '이미 저장한 주소입니다.');
                }
                return null;
              },
              onFieldSubmitted: (_) => save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_text(context, 'Cancel', '취소'))),
        TextButton(onPressed: save, child: Text(_text(context, 'Save', '저장'))),
      ],
    );
  }
}
