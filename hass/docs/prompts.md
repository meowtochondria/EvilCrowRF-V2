Evaluate if [@plan.md](file:///home/dev/src/EvilCrowRF-V2/hass/docs/plan.md) meets the following requirements. List strentghs, weaknesses, and suggestions to make the plan better. Focus should be on usability of the integration. The user should be able to onboard RF signals and replay them to control various devices via Home Assistant

I would like to use evilcrow wifi with home assistant to control various RF remote control devices. The end user should be able to able to learn all the buttons by pressing them and using evilcrow's Sub-Ghz functionality to capture the signal. to start, the person should be able to enter FCC ID of the device whose signal they're trying to capture. If they know the RF frequency at which the remote operates, they should be able to enter that instead. If given an FCC ID, the plugin should be able to query FCC APIs and determine the frequency on which the target device operates.
Once the signal is captured, the integration should ask the person to confirm operation by replaying the signal. If the person responds with a negative, then restart the signal capture and confirmation option, with another option to cancel and go back to home assitant.
The integration can communicate with evilcrow device over wifi. They will first need to setup that device. Add facility to connect to evilcrow device as first-run wizard. User should be able to skip it if they have already onboarded the device, and should be able to provide just the IP or FQDN.

In later iterations, we will be adding support for multiple evilcrow devices. Therefore, any communication between integration and home assitanct should include some form of device id. MAC address can change on firmware update, so don't depend on MAC address.

Methods of connecting to device and communicating with it can be found in [@architecture.md](file:///home/dev/src/EvilCrowRF-V2/firmware/docs/architecture.md) . A sample implementation exists in form of mobile app utilizing the same facilities. Docs related to it can be found at [@architecture.md](file:///home/dev/src/EvilCrowRF-V2/mobile_app/docs/architecture.md) .

Write a plan to implement it to [@plan.md](file:///home/dev/src/EvilCrowRF-V2/hass/docs/plan.md) . Include a makefile that allows developer to quickly test the changes. Use best practices to design the implementation.

use fccid.io instead for FCC API. downloading the page from https://fccid.io/{fcc_id} and looking for frequency seems to be working. Make this API endpoint configurable in settings. When the user updates the endpoint, scrape the page once and see if we are able to derive frequency from it or not. Leave it in that state, with an option to revert the configuration to default. Use `uv` for dependency management. Update the doc

I would like to add one more feature - the user may use the remote or the app to send RF signals. in that scenario, the state of the appliance acting on RF signal in home assistant will deviate from what's actually happening. Evilcrow RF has two CC11101 modules. Use one module to be always in listening mode, and match captured signal to what it already knows. If there is a match, then change the device status in Home Assistant accordingly. Allow user to configure if it this integration should also expose new signals that it detects. This can be noisy as random signals can be picked up from devices that do not belong to the user, so user should be able to turn this behavior on or off. Additionally, even if the capture mode is on, there is no guarantee that state would be perfectly reflected in home assistant - it can be due to distance from remote, general RF noise in the environment, and many other reasons i am not able to think of.


---
1. **Options flow does NOT match the user's requirement** (L683–L688)
Update document to apply suggestions.

2. **`SETTING_HA_DEVICE_ID_KEY = 0x01` is fabricated** (L172)

No value needs to be persisted to device itself. The reason to have UUIDs is to allow Home Assistant to contact intended device. It is completely possible that which device broadcasts which radio signals changes *after* learning the code/signal. This device id should be stored in config.txt on sdcard in device itself so that it survives resets. The device should report this back to the integration in response to a new hass-config-sync call so that existing communication with mobile app does not require a refactor. Update the plan to clarify this.

3. **Missing request/response timeout tracker
Update document to apply suggestions.

4. **No version negotiation**
Inform the user is major version is supported, but allow them to continue by dismissing the warning. Update doc to add version compatibility to integration.

5. **No file-list sync
Update document to apply suggestions. Additionally, user should be able to rename captured file so that they are able to use them via mobile app as well.

6. **`SubGhzService.handle_response` is incomplete**
Update document to apply suggestions.

7. **"Cancel and go back to Home Assistant" UX is undefined**
Update document to apply suggestions.

8. **`discovery.py` is in the directory tree but never described**
Update document to apply suggestions.

9. **Per-device vs integration-wide options not decided**
Move the FCC endpoint to .yml config file of the integration.

10. **`CapturedSignalEntity` uses `SensorEntity` for what is effectively metadata
`CapturedSignalEntity` should store all fields in captured signal. These fields should directly map to fields as exposed by Flipper sub file format.

11. **Missing `CMD_IDLE` (0x03) on cancel/timeou
Update document to apply suggestions.

12. **`Onboarding` step assumes STA→mDNS, but the firmware falls back to SoftAP**
We need to allow user to onboard the device to existing wifi or network. Consider updating firmware to use SmartConfig, and using that functionality to onboard device to wifi. Also apply suggestions.

13. **Reconfigure / reauth flow is missing
Update document to apply suggestions.

14. **Test plan is too thin**
Update document to apply suggestions.

16. **`Makefile` `run` target assumes `hass` CLI is available via `uv run`** 
Update document to apply suggestions.

17. **`pyproject.toml` lists `homeassistant>=2024.4` as a dev dep**
Update document to apply suggestions.

19. **No `make lock` target**
Update document to apply suggestions.

20. **No mention of `ConfigEntryState.NOT_READY` for offline devices**
Update document to add suggestions.

21. **No diagram of the multi-device dispatch in `__init__.py`**
Update document to add suggestions.

Gotchas
Add some fixes for them, unless they aren't already covered by changes or suggestions mentioned above.
12 - we utilize scraping FCC website for this.
