#pragma once

#include <od/graphics/ScreenSaver.h>
#include <cstdint>

namespace od
{

  class Maze : public ScreenSaver
  {
  public:
    Maze();
    virtual ~Maze();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    static const int COLS = 64;
    static const int ROWS = 16;
    static const int CELL_PX = 4;
    static const int TOTAL = COLS * ROWS; // 1024

    // Wall bits per cell
    static const uint8_t W_UP = 1;
    static const uint8_t W_RIGHT = 2;
    static const uint8_t W_DOWN = 4;
    static const uint8_t W_LEFT = 8;

    enum Phase
    {
      GENERATING,
      SOLVING,
      HOLDING
    };

    uint8_t walls[TOTAL];
    bool visited[TOTAL];

    int stack[TOTAL];
    int stackTop;

    int parent[TOTAL];
    int solvePath[TOTAL];
    int solveLen;
    int solveDrawIdx;

    Phase phase;
    float t = 0.0f;
    float stepAccum = 0.0f;
    float holdTimer = 0.0f;
    int marchOffset = 0;

    int cellIndex(int col, int row);
    void cellCoords(int idx, int &col, int &row);
    void computeSolvePath();
    void drawWalls(FrameBuffer &fb, int cellW, int cellH, int color);
    void drawMarchingBorder(FrameBuffer &fb, int w, int h, int color);
    void drawSolvePath(FrameBuffer &fb, int cellW, int cellH,
                       int color, int count);
  };

} /* namespace od */
