// Runs the production layer removal and compaction methods against focused
// doubles for chunk notifications and per-layer storage.
#include <algorithm>
#include <array>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

constexpr std::size_t MAX_TEXTURE_LAYERS = 16;
namespace ChunkUpdateFlags { constexpr int ALPHAMAP = 1; constexpr int FLAGS = 2; }
struct layer_info { unsigned flags = 0; unsigned effectID = 0xffffffffu; };
struct tmp_edit_alpha_values
{
  std::array<std::array<float, 4096>, MAX_TEXTURE_LAYERS> map{};
  auto& operator[](std::size_t index) { return map.at(index); }
};
struct Alphamap { int tag = 0; unsigned char getAlpha(unsigned) const { return static_cast<unsigned char>(tag); } };
struct Chunk { unsigned updates = 0; void registerChunkUpdate(int) { ++updates; } };
struct TextureSet
{
  std::vector<int> textures;
  std::array<std::unique_ptr<Alphamap>, MAX_TEXTURE_LAYERS - 1> alphamaps;
  std::array<layer_info, MAX_TEXTURE_LAYERS> _layers_info{};
  std::array<std::unique_ptr<int>, MAX_TEXTURE_LAYERS> heightTextures{};
  std::array<bool, MAX_TEXTURE_LAYERS> heightTextureOverrides{};
  std::array<int, MAX_TEXTURE_LAYERS> heightMappingData{};
  std::array<bool, MAX_TEXTURE_LAYERS> heightMappingDataOverrides{};
  std::unique_ptr<tmp_edit_alpha_values> tmp_edit_values;
  std::size_t nTextures = 0;
  Chunk chunk;
  Chunk* _chunk = &chunk;
  bool _need_lod_texture_map_update = false;

  void resetHeightMapping(std::size_t index)
  {
    heightTextures[index].reset(); heightTextureOverrides[index] = false;
    heightMappingData[index] = 0; heightMappingDataOverrides[index] = false;
  }
  void eraseTexture(std::size_t id);
  bool removeTextureLayer(std::size_t id);
};
// ACTUAL_ERASE_METHOD
// ACTUAL_REMOVE_METHOD

void require(bool ok, char const* message) { if (!ok) throw std::runtime_error(message); }
int main()
{
  try
  {
    TextureSet set;
    set.nTextures = 16;
    for (int i = 0; i < 16; ++i)
    {
      set.textures.push_back(100 + i);
      set._layers_info[i] = {static_cast<unsigned>(i + 10), static_cast<unsigned>(i + 20)};
      set.heightTextures[i] = std::make_unique<int>(i + 30);
      set.heightTextureOverrides[i] = true;
      set.heightMappingData[i] = i + 40;
      set.heightMappingDataOverrides[i] = true;
      if (i) { set.alphamaps[i - 1] = std::make_unique<Alphamap>(); set.alphamaps[i - 1]->tag = i * 10; }
    }
    require(!set.removeTextureLayer(0), "Base layer removal was accepted");
    require(!set.removeTextureLayer(16), "Out-of-range removal was accepted");
    require(set.nTextures == 16, "Rejected removal mutated the set");

    // Exercise the extended side of the 4/5 boundary with existing edits.
    set.tmp_edit_values = std::make_unique<tmp_edit_alpha_values>();
    for (std::size_t p = 0; p < 4096; ++p)
      for (std::size_t layer = 0; layer < 16; ++layer)
        (*set.tmp_edit_values)[layer][p] = static_cast<float>(layer + 1);
    require(set.removeTextureLayer(4), "Removal at index 4 failed");
    require(set.nTextures == 15 && set.textures[4] == 105, "Texture order did not compact");
    require((*set.tmp_edit_values)[0][0] == 6.f, "Removed coverage did not return to base");
    for (std::size_t layer = 1; layer < 15; ++layer)
    {
      float const expected = static_cast<float>(layer < 4 ? layer + 1 : layer + 2);
      require((*set.tmp_edit_values)[layer][0] == expected, "Remaining weight changed or shifted incorrectly");
    }
    require(set._layers_info[4].flags == 15 && set._layers_info[4].effectID == 25,
            "Layer flags/effect metadata detached during compaction");
    require(*set.heightTextures[4] == 35 && set.heightMappingData[4] == 45,
            "Height mapping metadata detached during compaction");
    require(set.alphamaps[3] && set.alphamaps[3]->tag == 50,
            "Alphamap after removed layer did not shift into place");
    require(set._chunk->updates > 0 && set._need_lod_texture_map_update,
            "Removal did not flag chunk/render data dirty");

    // Tail removal and last-layer protection.
    require(set.removeTextureLayer(14), "Last-index layer removal failed");
    while (set.nTextures > 2) require(set.removeTextureLayer(1), "Repeated non-base removal failed");
    require(set.removeTextureLayer(1), "Penultimate layer removal failed");
    require(!set.removeTextureLayer(0) && set.nTextures == 1, "Last texture was removable");

    TextureSet stored;
    stored.nTextures = 5;
    for (int i = 0; i < 5; ++i)
    {
      stored.textures.push_back(200 + i);
      if (i) { stored.alphamaps[i - 1] = std::make_unique<Alphamap>(); stored.alphamaps[i - 1]->tag = i * 10; }
    }
    require(stored.removeTextureLayer(2), "Stored-alpha removal failed");
    require((*stored.tmp_edit_values)[0][0] == 175.f, "Stored alpha did not move coverage to base");
    require((*stored.tmp_edit_values)[1][0] == 10.f && (*stored.tmp_edit_values)[2][0] == 30.f,
            "Stored remaining weights were altered");
    std::cout << "PASS: production layer removal, base fallback, metadata compaction, extended indices and bounds\n";
    return 0;
  }
  catch (std::exception const& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
