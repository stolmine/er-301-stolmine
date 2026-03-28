#include <od/graphics/screensavers/Pipes.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cstring>

namespace od
{

  Pipes::Pipes()
  {
    reset();
  }

  Pipes::~Pipes()
  {
  }

  int Pipes::dirBit(int dir)
  {
    static const uint8_t bits[] = {UP, RIGHT, DOWN, LEFT};
    return bits[dir & 3];
  }

  int Pipes::oppositeDir(int dir)
  {
    return (dir + 2) & 3;
  }

  void Pipes::colRowForDir(int col, int row, int dir, int &nc, int &nr)
  {
    nc = col;
    nr = row;
    switch (dir)
    {
    case 0: nr = row + 1; break; // up
    case 1: nc = col + 1; break; // right
    case 2: nr = row - 1; break; // down
    case 3: nc = col - 1; break; // left
    }
  }

  bool Pipes::inBounds(int col, int row)
  {
    return col >= 0 && col < COLS && row >= 0 && row < ROWS;
  }

  void Pipes::startNewPipe()
  {
    if (filledCells >= (COLS * ROWS * 85) / 100)
    {
      reset();
      return;
    }

    // Find a random empty cell
    for (int attempt = 0; attempt < 50; attempt++)
    {
      int c = Random::generateInteger(0, COLS - 1);
      int r = Random::generateInteger(0, ROWS - 1);
      if (grid[r * COLS + c] == 0)
      {
        curCol = c;
        curRow = r;
        curDir = Random::generateInteger(0, 3);
        curPipeColor = GRAY5 + Random::generateInteger(0, 10);
        if (curPipeColor > WHITE)
          curPipeColor = WHITE;
        return;
      }
    }

    // Couldn't find empty cell
    reset();
  }

  void Pipes::reset()
  {
    memset(grid, 0, sizeof(grid));
    memset(cellColor, 0, sizeof(cellColor));
    filledCells = 0;
    t = 0.0f;
    stepAccum = 0.0f;

    curCol = Random::generateInteger(0, COLS - 1);
    curRow = Random::generateInteger(0, ROWS - 1);
    curDir = Random::generateInteger(0, 3);
    curPipeColor = GRAY7 + Random::generateInteger(0, 8);
    if (curPipeColor > WHITE)
      curPipeColor = WHITE;
  }

  void Pipes::drawCell(FrameBuffer &fb, int col, int row,
                       int cellW, int cellH, int color)
  {
    uint8_t conn = grid[row * COLS + col];
    if (conn == 0)
      return;

    int px = col * cellW;
    int py = row * cellH;
    int cx = px + cellW / 2;
    int cy = py + cellH / 2;
    int hw = cellW > 4 ? 1 : 0; // half-width of pipe
    int hh = cellH > 4 ? 1 : 0;

    // Center junction
    fb.fill(color, cx - hw, cy - hh, cx + hw, cy + hh);

    // Arms toward connected edges
    if (conn & UP)
      fb.fill(color, cx - hw, cy, cx + hw, py + cellH - 1);
    if (conn & DOWN)
      fb.fill(color, cx - hw, py, cx + hw, cy);
    if (conn & RIGHT)
      fb.fill(color, cx, cy - hh, px + cellW - 1, cy + hh);
    if (conn & LEFT)
      fb.fill(color, px, cy - hh, cx, cy + hh);
  }

  void Pipes::draw(FrameBuffer &m, FrameBuffer &s)
  {
    t += GRAPHICS_REFRESH_PERIOD;
    if (t > 86400.0f)
      t = 0.0f;

    // Advance pipe growth
    stepAccum += 16.0f * GRAPHICS_REFRESH_PERIOD;
    while (stepAccum >= 1.0f)
    {
      stepAccum -= 1.0f;

      int nc, nr;
      colRowForDir(curCol, curRow, curDir, nc, nr);

      // Maybe turn before moving
      if (Random::generateFloat(0.0f, 1.0f) < 0.2f)
      {
        int tryDir = (curDir + (Random::generateFloat(0.0f, 1.0f) < 0.5f ? 1 : 3)) & 3;
        int tc, tr;
        colRowForDir(curCol, curRow, tryDir, tc, tr);
        if (inBounds(tc, tr) && grid[tr * COLS + tc] == 0)
        {
          curDir = tryDir;
          nc = tc;
          nr = tr;
        }
      }

      // Check if we can move forward
      if (!inBounds(nc, nr) || grid[nr * COLS + nc] != 0)
      {
        // Try both perpendicular directions
        bool found = false;
        int startTurn = Random::generateFloat(0.0f, 1.0f) < 0.5f ? 1 : 3;
        for (int i = 0; i < 2; i++)
        {
          int tryDir = (curDir + startTurn) & 3;
          int tc, tr;
          colRowForDir(curCol, curRow, tryDir, tc, tr);
          if (inBounds(tc, tr) && grid[tr * COLS + tc] == 0)
          {
            curDir = tryDir;
            nc = tc;
            nr = tr;
            found = true;
            break;
          }
          startTurn = (startTurn == 1) ? 3 : 1;
        }
        if (!found)
        {
          startNewPipe();
          continue;
        }
      }

      // Mark exit direction on current cell
      int idx = curRow * COLS + curCol;
      grid[idx] |= dirBit(curDir);
      if (cellColor[idx] == 0)
      {
        cellColor[idx] = curPipeColor;
        filledCells++;
      }

      // Move to next cell, mark entry direction
      curCol = nc;
      curRow = nr;
      idx = curRow * COLS + curCol;
      grid[idx] |= dirBit(oppositeDir(curDir));
      if (cellColor[idx] == 0)
      {
        cellColor[idx] = curPipeColor;
        filledCells++;
      }
    }

    // Render all cells
    for (int r = 0; r < ROWS; r++)
    {
      for (int c = 0; c < COLS; c++)
      {
        int idx = r * COLS + c;
        if (grid[idx] != 0)
        {
          drawCell(m, c, r, CELL, CELL, cellColor[idx]);
          drawCell(s, c, r, CELL_SUB_X, CELL_SUB_Y, WHITE);
        }
      }
    }
  }

} /* namespace od */
