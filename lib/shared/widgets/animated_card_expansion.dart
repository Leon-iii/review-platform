import 'package:flutter/material.dart';

const cardExpansionDuration = Duration(milliseconds: 200);

/// Animate header height changes (wrapping titles and compact badges) without
/// duplicating interactive headers, selection regions, or accessibility nodes.
class AnimatedCardHeader extends StatelessWidget {
  const AnimatedCardHeader({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : cardExpansionDuration,
    curve: Curves.easeInOutCubic,
    alignment: Alignment.topLeft,
    child: child,
  );
}

/// Retain one details subtree until collapse finishes. Reversing a transition
/// continues from its current value instead of recreating an outgoing child.
class AnimatedCardBody extends StatefulWidget {
  const AnimatedCardBody({
    required this.expanded,
    required this.child,
    super.key,
  });

  final bool expanded;
  final Widget child;

  @override
  State<AnimatedCardBody> createState() => _AnimatedCardBodyState();
}

class _AnimatedCardBodyState extends State<AnimatedCardBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _animation;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: cardExpansionDuration,
      value: widget.expanded ? 1 : 0,
    )..addStatusListener(_onStatusChanged);
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations) _controller.value = widget.expanded ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant AnimatedCardBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (_disableAnimations) {
      _controller.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded && _controller.isDismissed) {
      return const SizedBox.shrink();
    }
    return SizeTransition(
      sizeFactor: _animation,
      alignment: Alignment.topLeft,
      child: FadeTransition(
        opacity: _animation,
        child: IgnorePointer(
          ignoring: !widget.expanded,
          child: ExcludeSemantics(
            excluding: !widget.expanded,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
