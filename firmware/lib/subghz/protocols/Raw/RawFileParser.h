#ifndef Raw_FileParser_h
#define Raw_FileParser_h

#include "../SubGhzProtocol.h"
#include "../compatibility.h"
#include <sstream>

class RawFileParser : public SubGhzProtocol {
public:
    bool parse(File &file) override;
    std::vector<std::pair<uint32_t, bool>> getPulseData() const override;
    uint32_t getRepeatCount() const override;
    std::string serialize() const override;

private:
    mutable std::vector<std::pair<uint32_t, bool>> pulseData;
};

// Factory function
std::unique_ptr<SubGhzProtocol> createRawFileParser();

#endif // Raw_FileParser_h
