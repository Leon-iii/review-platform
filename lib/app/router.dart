import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/app_shell.dart';
import 'package:review_platform/features/home/home_view.dart';
import 'package:review_platform/features/library/folder_browser/folder_browser_view.dart';
import 'package:review_platform/features/library/question_editor/question_editor_view.dart';
import 'package:review_platform/features/settings/settings_view.dart';
import 'package:review_platform/features/statistics/statistics_view.dart';
import 'package:review_platform/features/study/quiz/quiz_view.dart';
import 'package:review_platform/features/study/result/quiz_result_view.dart';
import 'package:review_platform/features/study/setup/study_setup_view.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'router.g.dart';

abstract final class AppRoutes {
  static const home = '/';
  static const library = '/library';
  static const statistics = '/statistics';
  static const settings = '/settings';
  static const newQuestion = '/question/new';
  static const studySetup = '/study/setup';

  static String folder(String folderId) => '/library/folder/$folderId';
  static String editQuestion(String questionId) => '/question/$questionId/edit';
  static String studySession(String sessionId) => '/study/session/$sessionId';
  static String studyResult(String sessionId) => '/study/result/$sessionId';
  static String studySetupForWrong(String folderId) => Uri(
    path: studySetup,
    queryParameters: {'wrong': 'true', 'folderId': folderId},
  ).toString();
}

@Riverpod(keepAlive: true)
GoRouter router(Ref ref) {
  final rootNavigatorKey = GlobalKey<NavigatorState>();

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.home,
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(currentPath: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const HomeView(),
          ),
          GoRoute(
            path: AppRoutes.library,
            builder: (context, state) => const FolderBrowserView(),
            routes: [
              GoRoute(
                path: 'folder/:folderId',
                builder: (context, state) => FolderBrowserView(
                  folderId: state.pathParameters['folderId'],
                ),
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.statistics,
            builder: (context, state) => const StatisticsView(),
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsView(),
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: AppRoutes.newQuestion,
        builder: (context, state) =>
            QuestionEditorView(folderId: state.uri.queryParameters['folderId']),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: '/question/:questionId/edit',
        builder: (context, state) =>
            QuestionEditorView(questionId: state.pathParameters['questionId']),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: AppRoutes.studySetup,
        builder: (context, state) => StudySetupView(
          initialFolderId: state.uri.queryParameters['folderId'],
          onlyWrong: state.uri.queryParameters['wrong'] == 'true',
        ),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: '/study/session/:sessionId',
        builder: (context, state) =>
            QuizView(sessionId: state.pathParameters['sessionId']!),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: '/study/result/:sessionId',
        builder: (context, state) =>
            QuizResultView(sessionId: state.pathParameters['sessionId']!),
      ),
    ],
  );
}
