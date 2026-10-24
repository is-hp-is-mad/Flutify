import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/network/spotify_gateway.dart';
import '../../../../services/network/network_proxy.dart';
import 'settings_section.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton, M3ESwitch;
import '../../../widgets/flutify_dialog.dart';
import '../../../widgets/flutify_progress.dart';

class GatewaySettings extends StatelessWidget {
  final VoidCallback onChanged;
  const GatewaySettings({super.key, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final gateway = context.select<PreferencesProvider, SpotifyGateway>(
      (p) => p.prefs.gateway,
    );
    final l10n = context.l10n;
    final proxy = context.read<NetworkProxy?>();
    return StreamBuilder<void>(
      stream: proxy?.gatewayChanges,
      builder: (context, _) => Column(
        children: [
          SettingsTile(
            title: l10n.settingsGateway,
            subtitle: gateway.automatic
                ? l10n.settingsGatewayAutomatic
                : gateway.enabled
                ? gateway.baseUrl
                : l10n.settingsGatewayDescription,
            trailing: Semantics(toggled: gateway.automatic ? (proxy?.gateway.enabled ?? false) : gateway.enabled, child: M3ESwitch(
              value: gateway.automatic
                  ? (proxy?.gateway.enabled ?? false)
                  : gateway.enabled,
              onChanged: gateway.automatic
                  ? null
                  : (enabled) async {
                      if (enabled && !gateway.isValid) {
                        await _edit(context, gateway.copyWith(enabled: true));
                      } else {
                        _save(context, gateway.copyWith(enabled: enabled));
                      }
                    },
            )),
            onTap: () => _edit(context, gateway),
          ),
          if (gateway.automatic)
            SettingsTile(
              title: l10n.settingsGatewayAutomatic,
              subtitle: proxy?.gatewayLookupFailed == true
                  ? l10n.settingsGatewayLookupFailed
                  : proxy?.gatewayCountry == null
                  ? l10n.settingsGatewayCountryPending
                  : l10n.settingsGatewayCountryStatus(
                      proxy!.gatewayCountry!,
                      proxy.gateway.enabled
                          ? l10n.settingsGatewayRouteProxy
                          : l10n.settingsGatewayRouteDirect,
                    ),
              trailing: proxy?.gatewayChecking == true
                  ? const SizedBox.square(
                      dimension: 20,
                      child: FlutifySpinner(size: 20),
                    )
                  : IconButton(
                      tooltip: l10n.settingsGatewayRecheck,
                      onPressed: proxy?.refreshGatewayCountry,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
            ),
        ],
      ),
    );
  }

  void _save(BuildContext context, SpotifyGateway gateway) {
    final provider = context.read<PreferencesProvider>();
    provider.update(provider.prefs.copyWith(gateway: gateway));
    onChanged();
  }

  Future<void> _edit(BuildContext context, SpotifyGateway gateway) async {
    final result = await showDialog<SpotifyGateway>(
      context: context,
      builder: (_) => _GatewayDialog(gateway: gateway),
    );
    if (result != null && context.mounted) _save(context, result);
  }
}

class _GatewayDialog extends StatefulWidget {
  final SpotifyGateway gateway;
  const _GatewayDialog({required this.gateway});
  @override
  State<_GatewayDialog> createState() => _GatewayDialogState();
}

class _GatewayDialogState extends State<_GatewayDialog> {
  late final _url = TextEditingController(text: widget.gateway.baseUrl);
  late final _user = TextEditingController(text: widget.gateway.username);
  late final _pass = TextEditingController(text: widget.gateway.password);
  late final _countries = TextEditingController(
    text: widget.gateway.directCountries,
  );
  late bool _automatic = widget.gateway.automatic;
  bool _invalid = false;
  bool _countriesInvalid = false;
  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _countries.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FlutifyDialog(
      title: l10n.settingsGateway,
      content: Material(type: MaterialType.transparency, child: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.settingsGatewayDescription),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.settingsGatewayAutomatic),
                subtitle: Text(l10n.settingsGatewayAutomaticHelp),
                value: _automatic,
                onChanged: (value) => setState(() => _automatic = value),
              ),
              if (_automatic)
                TextField(
                  key: const ValueKey('gateway-countries'),
                  controller: _countries,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) {
                    if (_countriesInvalid) {
                      setState(() => _countriesInvalid = false);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: l10n.settingsGatewayDirectCountries,
                    hintText: 'US, JP, HK',
                    helperText: l10n.settingsGatewayDirectCountriesHelp,
                    helperMaxLines: 4,
                    errorText: _countriesInvalid
                        ? l10n.settingsGatewayCountriesInvalid
                        : null,
                  ),
                ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('gateway-url'),
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.settingsGatewayUrl,
                  hintText: 'https://host/path',
                ),
              ),
              TextField(
                key: const ValueKey('gateway-user'),
                controller: _user,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.settingsGatewayUser,
                ),
              ),
              TextField(
                key: const ValueKey('gateway-password'),
                controller: _pass,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.settingsGatewayPassword,
                ),
              ),
              if (_invalid)
                Text(
                  l10n.settingsGatewayInvalid,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      )),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        M3EButton.filled(
          onPressed: () {
            String countries;
            try {
              countries = _automatic
                  ? SpotifyGateway.normalizeCountries(_countries.text)
                  : widget.gateway.directCountries;
            } on FormatException {
              setState(() => _countriesInvalid = true);
              return;
            }
            final next = widget.gateway.copyWith(
              automatic: _automatic,
              directCountries: countries,
              baseUrl: _url.text.trim(),
              username: _user.text.trim(),
              password: _pass.text,
            );
            if (!next.isValid) {
              setState(() => _invalid = true);
              return;
            }
            Navigator.pop(context, next);
          },
          child: Text(l10n.settingsApply),
        ),
      ]);
  }
}
