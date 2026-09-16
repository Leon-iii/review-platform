import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.currentPath, required this.child, super.key});

  static const _destinations = [
    _Destination(
      label: '홈',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      route: AppRoutes.home,
    ),
    _Destination(
      label: '문제 관리',
      icon: Icons.library_books_outlined,
      selectedIcon: Icons.library_books_rounded,
      route: AppRoutes.library,
    ),
    _Destination(
      label: '통계',
      icon: Icons.insights_outlined,
      selectedIcon: Icons.insights_rounded,
      route: AppRoutes.statistics,
    ),
    _Destination(
      label: '설정',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      route: AppRoutes.settings,
    ),
  ];

  final String currentPath;
  final Widget child;

  int get _selectedIndex {
    if (currentPath.startsWith(AppRoutes.library)) return 1;
    if (currentPath.startsWith(AppRoutes.statistics)) return 2;
    if (currentPath.startsWith(AppRoutes.settings)) return 3;
    return 0;
  }

  void _navigate(BuildContext context, int index) {
    context.go(_destinations[index].route);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useNavigationRail = constraints.maxWidth >= 840;

        if (useNavigationRail) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  NavigationRail(
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: (index) => _navigate(context, index),
                    labelType: NavigationRailLabelType.all,
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Icon(Icons.school_rounded, size: 32),
                    ),
                    destinations: [
                      for (final destination in _destinations)
                        NavigationRailDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.selectedIcon),
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: child),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          body: child,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) => _navigate(context, index),
            destinations: [
              for (final destination in _destinations)
                NavigationDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: destination.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Destination {
  const _Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.route,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String route;
}
