import 'package:flutter/material.dart';

import 'features/presentation/app_theme.dart';
import 'features/presentation/app_view_model.dart';
import 'features/presentation/qi_day_flow_shell.dart';

class QiDayFlowApp extends StatelessWidget {
  const QiDayFlowApp({super.key, required this.viewModel});

  final QiDayFlowViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) {
        return MaterialApp(
          title: 'Qi Day Flow',
          debugShowCheckedModeBanner: false,
          theme: QiDayFlowTheme.light(),
          darkTheme: QiDayFlowTheme.dark(),
          themeMode: viewModel.settings.themeMode,
          home: QiDayFlowShell(viewModel: viewModel),
        );
      },
    );
  }
}
