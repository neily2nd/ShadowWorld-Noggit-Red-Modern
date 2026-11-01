#ifndef NOGGIT_CURSOR_WRAP_HPP
#define NOGGIT_CURSOR_WRAP_HPP

#include <QPoint>
#include <QRect>
#include <QLineF>

#include <algorithm>
#include <optional>

namespace Noggit::Ui::Tools::ViewportManager
{
  // The helper deliberately owns only wrapping geometry and warp-event state.
  // MapView remains responsible for deciding which interactions may wrap.
  class CursorWrap
  {
  public:
    [[nodiscard]] QLineF movementTo(
      QPointF event_position,
      std::optional<QPointF> current_cursor_position = std::nullopt)
    {
      // During wrapping, events may be delivered after the window system has
      // already moved the pointer again. Use the current pointer location so
      // stale event coordinates cannot produce a viewport-sized delta and
      // coalesced physical movement is retained.
      QPointF const position = current_cursor_position.value_or(event_position);
      QLineF const movement(_baseline, position);
      _baseline = position;
      return movement;
    }

    void rebase(QPointF position)
    {
      _baseline = position;
    }

    [[nodiscard]] std::optional<QPoint> target(QPoint position, QPoint movement, QRect bounds) const
    {
      if (bounds.width() < 2 || bounds.height() < 2)
        return std::nullopt;

      QPoint wrapped = position;
      bool needs_warp = false;
      wrapAxis(position.x(), movement.x(), bounds.left(), bounds.right(), wrapped.rx(), needs_warp);
      wrapAxis(position.y(), movement.y(), bounds.top(), bounds.bottom(), wrapped.ry(), needs_warp);

      return needs_warp ? std::optional<QPoint>(wrapped) : std::nullopt;
    }

    void expectWarpAt(QPoint global_position)
    {
      _expected_warp_position = global_position;
    }

    // A mismatching event may be queued before the warp event. Keep the warp
    // pending until its destination is observed; movement deltas use the
    // current cursor position and therefore do not depend on event order.
    bool observeWarpEvent(QPoint global_position)
    {
      if (!_expected_warp_position)
        return false;

      if (*_expected_warp_position != global_position)
        return false;

      _expected_warp_position.reset();
      return true;
    }

    void reset()
    {
      _expected_warp_position.reset();
    }

  private:
    static void wrapAxis(int position, int movement, int minimum, int maximum,
                         int& target, bool& needs_warp)
    {
      if (minimum >= maximum)
        return;

      // Keep a small inset for ordinary viewport sizes. For narrow viewports,
      // use the full axis so the destination cannot collapse to the same pixel.
      int const span = maximum - minimum + 1;
      int const inset = span > 6 ? 2 : 0;
      int const first = minimum + inset;
      int const last = maximum - inset;
      int const usable_span = last - first + 1;

      if (position > maximum || (position == maximum && movement > 0))
      {
        int const overshoot = std::max(0, position - maximum - 1);
        target = first + (overshoot % usable_span);
        needs_warp = true;
      }
      else if (position < minimum || (position == minimum && movement < 0))
      {
        int const overshoot = std::max(0, minimum - position - 1);
        target = last - (overshoot % usable_span);
        needs_warp = true;
      }
    }

    std::optional<QPoint> _expected_warp_position;
    QPointF _baseline;
  };
}

#endif
