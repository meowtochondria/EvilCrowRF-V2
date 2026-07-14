#ifndef All_Protocols_h
#define All_Protocols_h

#include "protocols/Princeton/PrincetonFileParser.h"
#include "protocols/Raw/RawFileParser.h"
#include "protocols/BinRAW/BinRAWFileParser.h"
#include "protocols/CAME/CAMEFileParser.h"
#include "protocols/NiceFlo/NiceFloFileParser.h"
#include "protocols/GateTX/GateTXFileParser.h"
#include "protocols/Holtek/HoltekFileParser.h"
#include "protocols/Honeywell48/Honeywell48FileParser.h"

// Real-time decoders
#include "protocols/BinRAW/BinRAWDecoder.h"
#include "protocols/Princeton/PrincetonDecoder.h"
#include "protocols/CAME/CAMEDecoder.h"
#include "protocols/GateTX/GateTXDecoder.h"
#include "protocols/Holtek/HoltekDecoder.h"
#include "protocols/NiceFlo/NiceFloDecoder.h"
#include "protocols/Honeywell48/Honeywell48Decoder.h"

#include "SubGhzProtocolDecoderRegistry.h"

namespace {
    struct RegisterAllProtocols {
        RegisterAllProtocols() {
            // File-parser protocols
            SubGhzProtocol::registerProtocol("Princeton", createPrincetonFileParser);
            SubGhzProtocol::registerProtocol("RAW", createRawFileParser);
            SubGhzProtocol::registerProtocol("BinRAW", createBinRAWFileParser);
            SubGhzProtocol::registerProtocol("CAME", createCAMEFileParser);
            SubGhzProtocol::registerProtocol("Nice FLO", createNiceFloFileParser);
            SubGhzProtocol::registerProtocol("Gate TX", createGateTXFileParser);
            SubGhzProtocol::registerProtocol("Holtek", createHoltekFileParser);
            SubGhzProtocol::registerProtocol("Honeywell 48bit", createHoneywell48FileParser);
            
            // Real-time decoders
            registerSubGhzDecoder("BinRAW",
                SubGhzProtocolDecoderBinRAW::PROTOCOL_FLAG,
                SubGhzProtocolDecoderBinRAW::vTable());
            registerSubGhzDecoder("Princeton",
                PrincetonDecoder::PROTOCOL_FLAG,
                PrincetonDecoder::vTable());
            registerSubGhzDecoder("CAME",
                CAMEDecoder::PROTOCOL_FLAG,
                CAMEDecoder::vTable());
            registerSubGhzDecoder("Gate TX",
                GateTXDecoder::PROTOCOL_FLAG,
                GateTXDecoder::vTable());
            registerSubGhzDecoder("Holtek",
                HoltekDecoder::PROTOCOL_FLAG,
                HoltekDecoder::vTable());
            registerSubGhzDecoder("Nice FLO",
                NiceFloDecoder::PROTOCOL_FLAG,
                NiceFloDecoder::vTable());
            registerSubGhzDecoder("Honeywell 48bit",
                Honeywell48Decoder::PROTOCOL_FLAG,
                Honeywell48Decoder::vTable());
        }
    };

    static RegisterAllProtocols registerAllProtocols;
}

#endif // All_Protocols_h
