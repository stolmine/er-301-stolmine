#pragma once

#include <od/extras/LockFreeQueue.h>
#include <emu/Window.h>
#include <hal/display.h>
#include <SDL2/SDL.h>
#include <map>
#include <queue>
#include <string>
#include <cstdint>

namespace emu
{
  struct Emulator
  {
    Emulator();
    int run(int argc, char **argv);
    void putDisplayBuffer(DisplayBuffer *buffer);
    DisplayBuffer *getDisplayBuffer();
    int getEncoderValue();
    bool isRearCardPresent();
    bool isFrontCardPresent();

  private:
    void loop();
    void handleKeyUp(SDL_Keysym sym);
    void handleKeyDown(SDL_Keysym sym);
    void handleMouseButton(SDL_MouseButtonEvent &e);
    void mapButtonToKey(uint32_t id, const std::string &key);

    // Scripted control channel (see emu/Control.h). Dispatch runs on the loop
    // thread, strictly in order, gated by wait/frames/stable/press/lua.
    enum class ControlGate { None, Wait, Frames, Stable, Press, Lua };
    void buildButtonNameMap();
    void serviceControl();
    void handleControlLine(const std::string &line);
    void onFrameRendered(DisplayBuffer *buffer);
    bool setSwitchPosition(uint32_t idA, uint32_t idB, const std::string &pos);

    bool headless = false;
    bool useControlChannel = false;
    std::string controlPath; // FIFO path when --control PATH is given

    std::map<std::string, uint32_t> nameButtonMap;
    std::queue<std::string> mPending;
    ControlGate mGate = ControlGate::None;
    int64_t mGateStartTicks = 0;
    double mGateMs = 0;
    long mGateFrameTarget = 0;
    uint32_t mPressButton = 0;
    long mFrameCount = 0;
    // stable-frames gate
    int mStableNeed = 0;
    int mStableCount = 0;
    long mStableTimeout = 0;
    long mStableStartFrame = 0;
    bool mStableHavePrev = false;
    DisplayBuffer mStablePrev;

    bool writeDefaultConfiguration(const std::string &filename);
    void loadDefaultConfiguration();
    bool loadConfiguration(const std::string &filename);
    std::string xRoot;
    std::string rearRoot;
    std::string frontRoot;
    std::string configRoot;
    std::string sessionFilename;
    std::string configFilename;
    double mouseWheelToKnobFactor;
    double leftRightToKnobFactor;
    double upDownToKnobFactor;
    bool rearCardPresent = true;
    bool frontCardPresent = true;

    // Persist state between sessions.
    void saveState();
    void restoreState();

    Window *window = 0;
    DisplayBuffer ping, pong;
    od::LockFreeQueue<DisplayBuffer *, 4> readyQ, renderQ;
    uint customEventType = SDL_USEREVENT;
    double encoderValue = 0;
    bool quit = false;
    bool storageToggleFocused = false;
    bool modeToggleFocused = false;

    // Keyboard Mapping
    std::map<std::string, uint32_t> keyGpioMap;
    std::map<uint32_t, std::string> gpioKeyMap;
    std::string storageToggleFocusKey;
    std::string modeToggleFocusKey;
    std::string zoomInKey;
    std::string zoomOutKey;
    std::string quitKey; // Must be modified with CTRL.

    // Mouse Mapping
    std::map<uint32_t, SDL_Rect> buttonHitMap;
    std::map<uint32_t, SDL_Rect> toggleHitMap;
  };
}