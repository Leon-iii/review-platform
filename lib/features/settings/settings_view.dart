import 'package:flutter/material.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('settings-view'),
      appBar: AppBar(title: const Text('설정')),
      body: const Center(child: Text('시스템 테마를 따르고 있어요.')),
    );
  }
}
