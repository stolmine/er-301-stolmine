#include <od/graphics/screensavers/Maze.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cstring>

namespace od
{

  Maze::Maze()
  {
    reset();
  }

  Maze::~Maze()
  {
  }

  int Maze::cellIndex(int col, int row)
  {
    return row * COLS + col;
  }

  void Maze::cellCoords(int idx, int &col, int &row)
  {
    col = idx % COLS;
    row = idx / COLS;
  }

  void Maze::reset()
  {
    memset(walls, 0x0F, sizeof(walls)); // all four walls
    memset(visited, 0, sizeof(visited));
    memset(parent, 0xFF, sizeof(parent)); // -1

    stackTop = 0;
    solveLen = 0;
    solveDrawIdx = 0;
    phase = GENERATING;
    t = 0.0f;
    stepAccum = 0.0f;
    holdTimer = 0.0f;

    // Start DFS from bottom-left
    int start = cellIndex(0, 0);
    visited[start] = true;
    stack[stackTop++] = start;
  }

  void Maze::computeSolvePath()
  {
    // BFS from (0,0) to (COLS-1, ROWS-1)
    int goal = cellIndex(COLS - 1, ROWS - 1);
    int start = cellIndex(0, 0);

    memset(parent, 0xFF, sizeof(parent));
    // Reuse stack as BFS queue
    int qHead = 0, qTail = 0;
    stack[qTail++] = start;
    parent[start] = start;

    while (qHead < qTail)
    {
      int cur = stack[qHead++];
      if (cur == goal)
        break;

      int col, row;
      cellCoords(cur, col, row);

      // Check each direction where wall is removed
      // Up
      if (!(walls[cur] & W_UP) && row < ROWS - 1)
      {
        int nb = cellIndex(col, row + 1);
        if (parent[nb] == -1)
        {
          parent[nb] = cur;
          stack[qTail++] = nb;
        }
      }
      // Right
      if (!(walls[cur] & W_RIGHT) && col < COLS - 1)
      {
        int nb = cellIndex(col + 1, row);
        if (parent[nb] == -1)
        {
          parent[nb] = cur;
          stack[qTail++] = nb;
        }
      }
      // Down
      if (!(walls[cur] & W_DOWN) && row > 0)
      {
        int nb = cellIndex(col, row - 1);
        if (parent[nb] == -1)
        {
          parent[nb] = cur;
          stack[qTail++] = nb;
        }
      }
      // Left
      if (!(walls[cur] & W_LEFT) && col > 0)
      {
        int nb = cellIndex(col - 1, row);
        if (parent[nb] == -1)
        {
          parent[nb] = cur;
          stack[qTail++] = nb;
        }
      }
    }

    // Trace path from goal to start
    solveLen = 0;
    int cur = goal;
    while (cur != start && solveLen < TOTAL)
    {
      solvePath[solveLen++] = cur;
      cur = parent[cur];
    }
    solvePath[solveLen++] = start;

    // Reverse
    for (int i = 0; i < solveLen / 2; i++)
    {
      int tmp = solvePath[i];
      solvePath[i] = solvePath[solveLen - 1 - i];
      solvePath[solveLen - 1 - i] = tmp;
    }
  }

  void Maze::drawWalls(FrameBuffer &fb, int cellW, int cellH, int color)
  {
    // Outer border
    fb.box(color, 0, 0, COLS * cellW - 1, ROWS * cellH - 1);

    for (int r = 0; r < ROWS; r++)
    {
      for (int c = 0; c < COLS; c++)
      {
        int idx = cellIndex(c, r);
        int px = c * cellW;
        int py = r * cellH;

        // Draw right wall (between this cell and neighbor to the right)
        if ((walls[idx] & W_RIGHT) && c < COLS - 1)
        {
          fb.vline(color, px + cellW, py, py + cellH);
        }
        // Draw top wall
        if ((walls[idx] & W_UP) && r < ROWS - 1)
        {
          fb.hline(color, px, px + cellW, py + cellH);
        }
      }
    }
  }

  void Maze::drawSolvePath(FrameBuffer &fb, int cellW, int cellH,
                           int color, int count)
  {
    for (int i = 0; i < count - 1 && i < solveLen - 1; i++)
    {
      int c0, r0, c1, r1;
      cellCoords(solvePath[i], c0, r0);
      cellCoords(solvePath[i + 1], c1, r1);

      int x0 = c0 * cellW + cellW / 2;
      int y0 = r0 * cellH + cellH / 2;
      int x1 = c1 * cellW + cellW / 2;
      int y1 = r1 * cellH + cellH / 2;

      fb.line(color, x0, y0, x1, y1);
    }
  }

  void Maze::draw(FrameBuffer &m, FrameBuffer &s)
  {
    t += GRAPHICS_REFRESH_PERIOD;
    if (t > 86400.0f)
      t = 0.0f;

    switch (phase)
    {
    case GENERATING:
    {
      stepAccum += 120.0f * GRAPHICS_REFRESH_PERIOD;
      while (stepAccum >= 1.0f && stackTop > 0)
      {
        stepAccum -= 1.0f;

        int cur = stack[stackTop - 1];
        int col, row;
        cellCoords(cur, col, row);

        // Collect unvisited neighbors
        int neighbors[4];
        int nCount = 0;

        if (row < ROWS - 1 && !visited[cellIndex(col, row + 1)])
          neighbors[nCount++] = 0; // up
        if (col < COLS - 1 && !visited[cellIndex(col + 1, row)])
          neighbors[nCount++] = 1; // right
        if (row > 0 && !visited[cellIndex(col, row - 1)])
          neighbors[nCount++] = 2; // down
        if (col > 0 && !visited[cellIndex(col - 1, row)])
          neighbors[nCount++] = 3; // left

        if (nCount > 0)
        {
          int pick = neighbors[Random::generateInteger(0, nCount - 1)];
          int nc = col, nr = row;

          switch (pick)
          {
          case 0: // up
            nr = row + 1;
            walls[cur] &= ~W_UP;
            walls[cellIndex(nc, nr)] &= ~W_DOWN;
            break;
          case 1: // right
            nc = col + 1;
            walls[cur] &= ~W_RIGHT;
            walls[cellIndex(nc, nr)] &= ~W_LEFT;
            break;
          case 2: // down
            nr = row - 1;
            walls[cur] &= ~W_DOWN;
            walls[cellIndex(nc, nr)] &= ~W_UP;
            break;
          case 3: // left
            nc = col - 1;
            walls[cur] &= ~W_LEFT;
            walls[cellIndex(nc, nr)] &= ~W_RIGHT;
            break;
          }

          int next = cellIndex(nc, nr);
          visited[next] = true;
          stack[stackTop++] = next;
        }
        else
        {
          stackTop--; // backtrack
        }
      }

      if (stackTop == 0)
      {
        computeSolvePath();
        phase = SOLVING;
        stepAccum = 0.0f;
      }
      break;
    }

    case SOLVING:
    {
      stepAccum += 60.0f * GRAPHICS_REFRESH_PERIOD;
      while (stepAccum >= 1.0f && solveDrawIdx < solveLen)
      {
        stepAccum -= 1.0f;
        solveDrawIdx++;
      }
      if (solveDrawIdx >= solveLen)
      {
        phase = HOLDING;
        holdTimer = 0.0f;
      }
      break;
    }

    case HOLDING:
    {
      holdTimer += GRAPHICS_REFRESH_PERIOD;
      if (holdTimer >= 4.0f)
      {
        reset();
      }
      break;
    }
    }

    // Render walls
    drawWalls(m, CELL_PX, CELL_PX, GRAY7);
    drawWalls(s, 2, 4, WHITE);

    // Render generation frontier
    if (phase == GENERATING && stackTop > 0)
    {
      int top = stack[stackTop - 1];
      int col, row;
      cellCoords(top, col, row);
      m.fill(WHITE, col * CELL_PX + 1, row * CELL_PX + 1,
             col * CELL_PX + CELL_PX - 2, row * CELL_PX + CELL_PX - 2);

      // Fading trail of recent stack entries
      int trailLen = stackTop < 20 ? stackTop : 20;
      for (int i = 0; i < trailLen; i++)
      {
        int idx = stack[stackTop - 1 - i];
        int tc, tr;
        cellCoords(idx, tc, tr);
        int brightness = GRAY10 - i;
        if (brightness < GRAY1)
          brightness = GRAY1;
        m.pixel(brightness, tc * CELL_PX + CELL_PX / 2,
                tr * CELL_PX + CELL_PX / 2);
      }
    }

    // Render solve path
    if (phase == SOLVING || phase == HOLDING)
    {
      int count = (phase == HOLDING) ? solveLen : solveDrawIdx;
      drawSolvePath(m, CELL_PX, CELL_PX, WHITE, count);
      drawSolvePath(s, 2, 4, WHITE, count);
    }
  }

} /* namespace od */
