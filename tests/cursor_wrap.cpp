#include <noggit/ui/tools/ViewportManager/CursorWrap.hpp>

#include <cmath>
#include <iostream>
#include <QString>
#include <string_view>

namespace
{
  int failures = 0;

  void expect(bool condition, std::string_view description)
  {
    if (!condition)
    {
      std::cerr << "FAIL: " << description << '\n';
      ++failures;
    }
  }

  void expectMovement(QLineF const& movement, double dx, double dy, std::string_view description)
  {
    expect(std::abs(movement.dx() - dx) < 0.001 && std::abs(movement.dy() - dy) < 0.001,
           description);
  }

  void checkEdgeSequence(QString const& name, QRect const& bounds, QPoint global_origin,
                         QPoint baseline, QPoint edge_position, QPoint post_wrap,
                         QPoint stale_event_position, QPoint real_after_wrap)
  {
    using Noggit::Ui::Tools::ViewportManager::CursorWrap;
    CursorWrap wrap;
    wrap.rebase(baseline);

    QLineF const triggering_move = wrap.movementTo(edge_position, edge_position);
    auto const wrap_target = wrap.target(edge_position,
      QPoint(qRound(triggering_move.dx()), qRound(triggering_move.dy())), bounds);
    expect(wrap_target.has_value(), name.toStdString() + ": boundary movement wraps");
    if (!wrap_target)
      return;

    QPoint const global_target = global_origin + *wrap_target;
    QPoint const global_source = global_origin + edge_position;
    wrap.rebase(*wrap_target);
    wrap.expectWarpAt(global_target);

    // A queued move from the pre-warp edge arrives before the cursor-warp event.
    expect(!wrap.observeWarpEvent(global_source),
           name.toStdString() + ": stale event leaves warp pending");
    QLineF const stale_move = wrap.movementTo(stale_event_position, post_wrap);
    expectMovement(stale_move, 0.0, 0.0,
                   name.toStdString() + ": stale edge coordinates add no false movement");
    expect(std::abs(stale_move.dx()) < bounds.width()
           && std::abs(stale_move.dy()) < bounds.height(),
           name.toStdString() + ": no viewport-sized delta reaches tools");

    // Physical motion can be coalesced with, or arrive before, the warp event.
    QLineF const coalesced_move = wrap.movementTo(stale_event_position, real_after_wrap);
    expectMovement(coalesced_move, real_after_wrap.x() - post_wrap.x(),
                   real_after_wrap.y() - post_wrap.y(),
                   name.toStdString() + ": coalesced physical motion is retained");
    expect(!wrap.observeWarpEvent(global_source),
           name.toStdString() + ": another mismatching event does not clear the warp");

    // The expected warp event is acknowledged but does not discard movement
    // already reflected in the current cursor position.
    expect(wrap.observeWarpEvent(global_target),
           name.toStdString() + ": delayed warp event is recognized");
    QLineF const warp_event_move = wrap.movementTo(*wrap_target, real_after_wrap);
    expectMovement(warp_event_move, 0.0, 0.0,
                   name.toStdString() + ": delayed warp event introduces no jump");

    QPoint const responsive_position = real_after_wrap + QPoint(3, 2);
    QLineF const responsive_move = wrap.movementTo(responsive_position, responsive_position);
    expectMovement(responsive_move, 3.0, 2.0,
                   name.toStdString() + ": normal movement remains responsive");
  }
}

int main()
{
  using Noggit::Ui::Tools::ViewportManager::CursorWrap;
  QRect const viewport(0, 0, 100, 80);

  expect(CursorWrap{}.target(QPoint(99, 30), QPoint(4, 0), viewport) == QPoint(2, 30),
         "right edge wraps to the left inset");
  expect(CursorWrap{}.target(QPoint(0, 30), QPoint(-3, 0), viewport) == QPoint(97, 30),
         "left edge wraps to the right inset");
  expect(CursorWrap{}.target(QPoint(40, 79), QPoint(0, 2), viewport) == QPoint(40, 2),
         "bottom edge wraps to the top inset");
  expect(CursorWrap{}.target(QPoint(40, 0), QPoint(0, -2), viewport) == QPoint(40, 77),
         "top edge wraps to the bottom inset");
  expect(!CursorWrap{}.target(QPoint(99, 30), QPoint(-1, 0), viewport),
         "inward movement at the right edge does not wrap");
  expect(!CursorWrap{}.target(QPoint(50, 30), QPoint(1, 1), viewport),
         "movement away from edges does not wrap");
  expect(CursorWrap{}.target(QPoint(250, 30), QPoint(155, 0), viewport) == QPoint(56, 30),
         "large overshoot maps back into the viewport");

  checkEdgeSequence("right", viewport, QPoint(-1920, 0), QPoint(98, 30),
                    QPoint(99, 30), QPoint(2, 30), QPoint(99, 30), QPoint(8, 35));
  checkEdgeSequence("left", viewport, QPoint(-1920, 0), QPoint(1, 30),
                    QPoint(0, 30), QPoint(97, 30), QPoint(0, 30), QPoint(93, 35));
  checkEdgeSequence("bottom", viewport, QPoint(0, -1080), QPoint(40, 78),
                    QPoint(40, 79), QPoint(40, 2), QPoint(40, 79), QPoint(45, 8));
  checkEdgeSequence("top", viewport, QPoint(0, -1080), QPoint(40, 1),
                    QPoint(40, 0), QPoint(40, 77), QPoint(40, 0), QPoint(45, 73));

  CursorWrap reset_wrap;
  reset_wrap.rebase(QPoint(99, 30));
  reset_wrap.expectWarpAt(QPoint(2, 30));
  reset_wrap.reset();
  expect(!reset_wrap.observeWarpEvent(QPoint(2, 30)),
         "focus loss or cancellation clears pending warp state");
  reset_wrap.rebase(QPoint(4, 30));
  expectMovement(reset_wrap.movementTo(QPoint(4, 30), QPoint(4, 30)), 0.0, 0.0,
                 "cancellation can rebase before normal input resumes");

  CursorWrap ordinary_motion;
  ordinary_motion.rebase(QPoint(10, 10));
  expectMovement(ordinary_motion.movementTo(QPoint(13, 14)), 3.0, 4.0,
                 "ordinary non-wrapped movement remains responsive");

  // Two consecutive wraps must each use the new cursor position as baseline.
  CursorWrap repeated;
  repeated.rebase(QPoint(98, 20));
  QLineF const first_delta = repeated.movementTo(QPoint(99, 20), QPoint(99, 20));
  auto const first_target = repeated.target(QPoint(99, 20),
    QPoint(qRound(first_delta.dx()), qRound(first_delta.dy())), viewport);
  expect(first_target == QPoint(2, 20), "first consecutive wrap target");
  repeated.rebase(*first_target);
  QLineF const after_first_wrap = repeated.movementTo(QPoint(99, 20), QPoint(99, 20));
  expect(after_first_wrap.dx() == 97.0, "physical movement to the next edge is represented");
  auto const second_target = repeated.target(QPoint(99, 20),
    QPoint(qRound(after_first_wrap.dx()), 0), viewport);
  expect(second_target == QPoint(2, 20), "second consecutive wrap target");
  repeated.rebase(*second_target);
  expectMovement(repeated.movementTo(QPoint(99, 20), QPoint(2, 20)), 0.0, 0.0,
                 "stale event after repeated wrap cannot create a jump");

  return failures == 0 ? 0 : 1;
}
