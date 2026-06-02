#pragma once
/**
 * @file PPAllProtocols.h
 * @brief Master include for all ProtoPirate protocol decoders.
 *
 * Including this file registers all protocol classes
 * via the PP_REGISTER_PROTOCOL() macro.
 */

// Automotive key fob protocols
#include "PPSuzuki.h"
#include "PPSubaru.h"
#include "PPKiaV0.h"
#include "PPKiaV1.h"
#include "PPKiaV2.h"
#include "PPKiaV3V4.h"
#include "PPKiaV5.h"
#include "PPKiaV6.h"
#include "PPFiatV0.h"
#include "PPFordV0.h"
#include "PPScherKhan.h"
#include "PPStarLine.h"
#include "PPVag.h"
#include "PPPsa.h"
