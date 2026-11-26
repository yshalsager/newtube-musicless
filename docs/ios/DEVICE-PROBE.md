# Device probe: iPhone 13 mini (US-002)

What the test phone's OS and hardware allow, measured by the app's debug screen (Debug → Device
probe on the placeholder screen; or launch with `--run-probe`). Later stories cite these figures instead of guessing.
No device name or UDID appears here, by rule (`ios/CLAUDE.md`).

**How it was captured** (2026-11-25): Debug build of commit `7ed92917` plus the uncommitted
Phase 0 tree, installed on the pinned phone and launched with
`xcrun devicectl device process launch --device "$DEVICE_ID" --console <bundle id> --run-probe`;
the report below is the `[Probe] probe …` lines from that console, unedited.

## What it means for later stories

| Finding | Consequence |
|---|---|
| Xcode 26.4 (SDK 26.4) builds, installs and launches on iOS 26.6.2 | PRD §9's Xcode/iOS mismatch risk is closed; no Xcode update needed |
| `vp09`: no hardware decode as shipped, **yes after `VTRegisterSupplementalVideoDecoderIfAvailable`** | US-034 (VP9 above 1080p) is viable on this phone. The bare-session result (`-8971`) agrees: the decoder answers and only wants a `vpcC` atom |
| `av01`: no decoder, before or after (`kVTCouldNotFindVideoDecoderErr`) | AV1 needs software decoding on the A15; it stays out (PRD §7) |
| Neural Engine present, 16 cores; Core ML also lists the A15 GPU and the CPU | US-006 can compare `ALL` and `CPUAndNeuralEngine` as planned |
| `BGTaskScheduler.supportedResources` = 0: **no background GPU** | The `continued-processing.gpu` entitlement (PRD §4.6) buys nothing on this phone; background separation is CPU and Neural Engine only, as §4.5 already plans. Measured without that entitlement and without the `processing` background mode; recheck once when Phase 5 adds them |
| `os_proc_available_memory()` = 2088 MiB at launch, without the Increased Memory Limit entitlement | The 700 MB playing budget (§4.5) fits with room to spare before that entitlement; US-005/US-006 record the figure again with both models loaded |
| Audio hardware runs at **48 kHz**, IO buffer 1024 frames (21.3 ms), output latency 12.6 ms on the speaker | The separator works at 44.1 kHz (the model's rate). `AVSampleBufferAudioRenderer` should resample to the hardware rate on output, so the pipeline would need no resampler of its own [verify in US-012]. A/V sync (US-013) must use the renderer's timestamps, not frame counts at 48 kHz |
| Screen 1080 x 2340 px, 60 Hz | Confirms §4.2's video cap: 1080p is the screen's width; no reason to decode above 60 fps |
| The probe takes 49 ms (176 ms on the first launch after install) | Cheap enough to run on every open of the screen |

## Report

```
# NewTube Musicless device probe
generated: 2026-11-25T13:17:14Z
app: 0.1.0 (1) · 7ed92917-dirty
probe took: 49 ms

## System
- iOS: 26.6.2
- OS build: Version 26.6.2 (Build 23G90)
- model identifier: iPhone14,4
- simulator: no
- CPU cores (active/total): 6/6
- Metal GPU: Apple A15 GPU
- build configuration: Debug

## Memory
- physical memory: 3676 MiB (3854663680 bytes)
- os_proc_available_memory(): 2088 MiB (2189245688 bytes)
- phys_footprint (this app now): 10 MiB (10666760 bytes)

## Power and thermal
- thermal state: nominal
- Low Power Mode: off

## Screen
- native pixels (portrait): 1080 x 2340
- native scale: 2.88
- max frames per second: 60

## Video decode
- VTRegisterSupplementalVideoDecoderIfAvailable: called for vp09 and av01
- "before" column: first probe since launch: decoders as the OS ships them
- avc1 hardware decode (before / after): yes / yes
- hvc1 hardware decode (before / after): yes / yes
- vp09 hardware decode (before / after): no / yes
- av01 hardware decode (before / after): no / no
- avc1 bare session create (after): 0 (OK)
- hvc1 bare session create (after): -8971 (codecExtensionNotFoundErr: decoder present, needs its config atom)
- vp09 bare session create (after): -8971 (codecExtensionNotFoundErr: decoder present, needs its config atom)
- av01 bare session create (after): -12906 (kVTCouldNotFindVideoDecoderErr)

## Core ML
- MLModel.availableComputeDevices: Neural Engine (16 cores), GPU (Apple A15 GPU), CPU
- MLComputeDevice.allComputeDevices: Neural Engine (16 cores), GPU (Apple A15 GPU), CPU

## Background tasks
- BGTaskScheduler.supportedResources (raw): 0
- background GPU (.gpu): no

## Audio session
- inactive: sample rate: 48000 Hz
- inactive: IO buffer duration: 21.33 ms (1024 frames)
- inactive: output latency: 12.60 ms
- inactive: output channels: 2
- inactive: route outputs: Speaker
- active: sample rate: 48000 Hz
- active: IO buffer duration: 21.33 ms (1024 frames)
- active: output latency: 12.60 ms
- active: output channels: 2
- active: route outputs: Speaker
```

**Reading the video rows.** "Hardware decode" is `VTIsHardwareDecodeSupported`. "Bare session
create" opens any decoder (hardware or software) for a format description with no codec
configuration: `0` means a decoder accepted it, `-8971` means a decoder exists but needs its
configuration atom, `-12906` means no decoder at all. The "before" column is only true on the first
probe after a launch, because the registration lasts for the process.

**Simulator, for contrast** (iPhone 13 mini simulator, iOS 26.4, same build): no hardware decode
for any codec, Core ML lists only GPU and CPU, `os_proc_available_memory()` reports 0 (no limit),
audio at 48 kHz with a 10 ms buffer. None of it says anything about the phone.
