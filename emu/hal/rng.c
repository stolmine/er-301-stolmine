#include <hal/rng.h>
#include <hal/log.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

// [stol:emu-seed-flag]
// When seeded (emu --seed N), Rng_read32/64 return a deterministic PRNG stream
// (splitmix64) so runs that consume randomness reproduce byte-for-byte. Without
// a seed the behaviour is unchanged: read from /dev/urandom exactly as before.
// Declared here (not in hal/rng.h) so the firmware header stays untouched.
void Rng_seed(uint32_t seed);

static bool seeded = false;
static uint64_t prngState = 0;

void Rng_seed(uint32_t seed)
{
  seeded = true;
  prngState = (uint64_t)seed;
  logInfo("RNG seeded deterministically with %u.", seed);
}

static uint64_t splitmix64(void)
{
  prngState += 0x9E3779B97F4A7C15ULL;
  uint64_t z = prngState;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

void Rng_init(void)
{
}

uint64_t Rng_read64(void)
{
  if (seeded)
  {
    return splitmix64();
  }

  uint64_t output;
  FILE *f = fopen("/dev/urandom", "r");
  if (f)
  {
    if (fread(&output, sizeof(uint64_t), 1, f) != 1)
    {
      logError("Could not read from /dev/urandom.");
    }
    fclose(f);
  }
  else
  {
    logError("Could not open /dev/urandom.");
  }
  return output;
}

uint32_t Rng_read32(void)
{
  if (seeded)
  {
    return (uint32_t)(splitmix64() >> 32);
  }

  uint32_t output;
  FILE *f = fopen("/dev/urandom", "r");
  if (f)
  {
    if (fread(&output, sizeof(uint32_t), 1, f) != 1)
    {
      logError("Could not read from /dev/urandom.");
    }
    fclose(f);
  }
  else
  {
    logError("Could not open /dev/urandom.");
  }
  return output;
}
