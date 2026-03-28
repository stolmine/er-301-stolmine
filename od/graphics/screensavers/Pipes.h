#pragma once

#include <od/graphics/ScreenSaver.h>
#include <cstdint>

namespace od
{

  class Pipes : public ScreenSaver
  {
  public:
    Pipes();
    virtual ~Pipes();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    static const int COLS = 32;
    static const int ROWS = 8;
    static const int CELL = 8;
    static const int CELL_SUB_X = 4;
    static const int CELL_SUB_Y = 8;

    // Direction bits
    static const uint8_t UP = 1;
    static const uint8_t RIGHT = 2;
    static const uint8_t DOWN = 4;
    static const uint8_t LEFT = 8;

    uint8_t grid[COLS * ROWS];
    uint8_t cellColor[COLS * ROWS];

    int curCol, curRow;
    int curDir; // 0=up,1=right,2=down,3=left
    int curPipeColor;
    int filledCells;

    float t = 0.0f;
    float stepAccum = 0.0f;

    void startNewPipe();
    int dirBit(int dir);
    int oppositeDir(int dir);
    void colRowForDir(int col, int row, int dir, int &nc, int &nr);
    bool inBounds(int col, int row);
    void drawCell(FrameBuffer &fb, int col, int row,
                  int cellW, int cellH, int color);
  };

} /* namespace od */
