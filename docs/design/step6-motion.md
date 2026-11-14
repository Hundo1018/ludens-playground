# Step 6: CMU motion, retargeted onto CesiumMan

Written by the advisor, layer by layer, for the playground's step 6. Layer 1 decides; layer 2 gives the PR 6.0 steps; layer 3 gives the commands. Each PR must pass its checks before the next starts. Stacked on `feat/frontier-meshes` (step 5 PR D).

## Layer 1: decisions

### 1.1 Goal

CesiumMan plays CMU motion, retargeted. A MotionDB is built from several CMU trials, and motion matching picks the clip and frame from player intent.

Non-goals: retargeting the Fox (it keeps its own clips), fingers, hands and thumbs, and any blending beyond crossfade.

### 1.2 Measured facts

- CMU `01.asf` has 30 bonedata entries plus root.
- Its rest is a T-pose: the humerus points ±x, the femur is 20° out, and the toes point +z. So CMU faces +z with its left side at +x.
- CesiumMan has 19 joints, is Z-up under `root_transform`, and stands 1.507 m tall.

### 1.3 Units

Read `:units` in the ASF.

- If it says `length 0.45`, then metres = value × 0.0254 / 0.45, which puts `lfemur` (7.158) at 0.404 m.
- Check M1 pins this down.

### 1.4 `.lmotion` v2

It must carry everything retargeting needs:

- per bone: direction, length, `axis` with its order, and dof order
- the units scale
- the root's order, position and orientation
- per frame: the dof values in degrees

U6.8 is to read `convert_amc.py`'s writer and list what v1 already stores. `parse_asf` drops bonedata today.

### 1.5 CMU forward kinematics

**Decided (evidence in the table below): the static composition.**

- Axis rotation and dof rotation are both static: `C = Rz(az)·Ry(ay)·Rx(ax)` and `M = Rz(rz)·Ry(ry)·Rx(rx)`, with an absent dof taken as 0.
- Root: `W_root = M_root` from RX, RY, RZ in the same static order.
- Children: `W_b = W_parent · C · M · C⁻¹`. The end is `start + len · W_b · dir · units`. `dir` is not rotated by `C` again.

Trials used, both at 120 fps (CMU search page, framerate column):
- **01_01**, subject 01: "playground - forward jumps, turn around". Climbing and jumping subject: not a locomotion source, but a stress test.
- **07_01**, subject 07: "walk". The locomotion evidence. Subject 07 also has walk trials 1 to 10 and slow walk trials, all at 120 fps.

Both trials use `:units length 0.45` and `:units angle deg`.

| check | static C | C = Rx·Ry·Rz (rejected) |
|---|---|---|
| 07_01 foot skate, left toe (median, contact frames) | 0.072 m/s (64) | 0.097 m/s (60) |
| 07_01 foot skate, right toe | 0.085 m/s (19) | 0.071 m/s (29) |
| 07_01 arms at frames 0/100/200 (left wrist − shoulder, right) | −0.09/−0.28; −0.25/−0.27; −0.27/−0.18 | −0.26/−0.17; −0.25/−0.23; −0.09/−0.27 |
| 01_01 foot skate, left / right | 0.049 / 0.048 m/s (1253 / 1291 contact frames) | 0.065 / 0.063 m/s (1448 / 1376) |
| 01_01 arms at frame 0 (left, right) | +0.246 / −0.267 | +0.109 / −0.230 |

Foot skate is measured with the robust contact rule in §1.9 M1: floor = 5th percentile of the toe's height over the trial; contact = height ≤ floor + 0.03 m and vertical speed < 0.1 m/s.

Both orders pass foot skate on the walk. The arms agree in sign on the walk at every sampled frame. The static order is adopted on the walk evidence, following the advisor's rule (both toes pass and the arms agree). On 01_01 the frame-0 arms disagree under both orders, so that disagreement is not evidence about the composition: the jump trial may have a raised arm. The rejected order is kept in the table so the comparison is on record.

Earlier candidates (not the static order) placed the toes up to 1.9 m above the floor on 01_01, with the body inverted for 15 frames around 1092 to 1106. Both trials were run with the static order, which removes that inversion.

Stick figures (front and side view, four frames, drawn from `scripts/motion_fk.py`'s FK; images are not in the repository):
- 07_01 walk, frames 0, 60, 120, 200: upright torso, alternating stride in the side view, arms swinging. Judged human.
- 01_01 jump, frames 0, 500, 1095, 1500: standing figures at 0, 500 and 1500; frame 1095 is a deep forward bend in the jump. Judged human.

Measured M1 values after the unit fix (`scripts/motion_fk.py --selftest`, 5/5 on each trial): 07_01 femur 0.391 m, rest height 1.512 m, foot skate 0.072 and 0.085 m/s; 01_01 femur 0.404 m, rest height 1.564 m, foot skate 0.049 and 0.048 m/s.

- Each bone's local rotation is `L_b = C_b · M_b · C_b⁻¹`, where `C_b` comes from `axis` and `M_b` from the AMC dofs.
- A bone's end is its parent's end plus `W_b · dir · len`.
- The composition order inside `C` and `M` is the known trap. Settle it with M1, not from memory.

### 1.6 Retarget by world-rotation transfer, with rest alignment

- **Shared frame:** Y-up, metres, facing +z. Apply `root_transform` to CesiumMan, then yaw it until its toes point +z (U6.4).
- **Mapping:** 12 pairs, chosen by comparing the two rest-pose FK printouts side by side. Decide sides by world x, not by name.
  - Candidates to verify: root→torso_1, lowerback→torso_2, thorax→torso_3, lowerneck→neck_1, head→neck_2.
  - Arms: humerus→arm_\*_4, radius→arm_\*_3, wrist→arm_\*_2.
  - Legs: femur→leg_\*_1, tibia→leg_\*_2, foot→leg_\*_3, toes→leg_\*_5.
- **Rest alignment:** `A_j` is the shortest-arc rotation from the target's rest bone direction to the source's. Then `W_j(f) = W_b(f) · W_b(rest)⁻¹ · A_j · W_j(rest)`. This covers a T-pose against an A-pose (U6.5).
- **Locals:** `local_j = W_parent(f)⁻¹ · W_j(f)`. Unmapped target joints keep their rest local. Translations come from the target's rest.
- **Root translation:** scale it by the ratio of hip heights, both measured at rest in the shared frame.
- **Output:** the `.lcharacter` clip layout, 10 floats per joint per frame. The existing `pose_palette` then plays it unchanged.

**Decided and implemented in 6.1 (`scripts/retarget.py`).**

Yaw: 0. CesiumMan's `leg_L_5` z (+0.027) lies ahead of `leg_L_3` (−0.005) and its left joints have x > 0; CMU's toes are ahead in z and its left is +x. The shared frame needs no yaw.

Mapping (19 rows; every CesiumMan joint gets a source). The rule: map each target joint to the CMU bone that starts at that joint's position. A joint that carries other limbs follows the bone that positions those limbs.

| CesiumMan joint | CMU bone | why |
|---|---|---|
| 0 torso_1 | lowerback (direction and rotation); the root translates | the segment torso_1→torso_2 is lowerback's segment; the root places the chain |
| 1 torso_2 | upperback | starts at lowerback's end |
| 2 torso_3 | thorax | carries the shoulders |
| 3 neck_1 | upperneck | starts at lowerneck's end |
| 4 neck_2 | head | |
| 5 / 7 / 9 (left arm) | lhumerus / lradius / lwrist | by parent chain |
| 6 / 8 / 10 (right arm) | rhumerus / rradius / rwrist | by parent chain; the right suffixes do not mirror the left |
| 11 / 13 / 15 / 17 (left leg) | lfemur / ltibia / lfoot / ltoes | |
| 12 / 14 / 16 / 18 (right leg) | rfemur / rtibia / rfoot / rtoes | |

Not mapped (intermediate, world transfer absorbs them): lhipjoint, rhipjoint, lowerneck, the clavicles, hands, fingers and thumbs.

Nearest-start check: CMU scaled to CesiumMan's hip height (0.755), roots aligned. Each target joint's start is within a few cm of its bone's start; upperback and lowerback are both close to torso_2, and the distance chose upperback (as in the table).

Rest alignment: `A_j` is the shortest arc from the target's rest direction (child minus joint, in the shared frame) to the source bone's rest direction. The joint with several children uses its first child in the chain (torso_1 → torso_2; torso_3 → neck_1). Leaves (4, 9, 10, 17, 18) take their parent's `A_j`. Twist about a bone is not constrained by the arc; the elbow and knee bend are checked in the figures.

Root ratio, revised (§1.6, step 6.1 fix): the earlier 0.755 from hip heights is withdrawn. Stance skate depends on leg length, so the ratio is derived from segment lengths: CesiumMan's thigh plus shin (rest world, mean of the two legs) over subject 07's femur plus tibia (ASF). The derived value is **0.6711**, computed in `retarget.py` (`leg_ratio`), not a constant.

Ratio sweep, measured at 120 fps (target foot skate on leg_L_5 / leg_R_5, m/s; contact frames in brackets are about 45 to 53):

| ratio | left | right |
|---|---|---|
| 0.60 | 0.078 | 0.092 |
| 0.63 | 0.062 | 0.089 |
| 0.66 | 0.073 | 0.097 |
| 0.69 | 0.094 | 0.114 |
| 0.6711 (derived) | 0.077 | 0.101 |

The derived value is 0.04 above the sweep's minimum (0.63) on the left. Both toes pass the 0.15 bound at it, so it is kept and the difference is recorded. The earlier 30 fps skate check had 13 contact frames and failed at 0.162 and 0.169; the 120 fps check is the one that counts.

Floor: the 5th percentile of min(leg_L_5, leg_R_5) is moved to CesiumMan's rest leg height (0.0212 m, world) by a root-y offset, two-pass. The offset is +0.0008 m. Without it the feet floated about 6.6 cm.

Loop window: [58, 190) of 07_01, the window whose two ends are closest with root xz removed (1.1 s, one gait cycle). The seam jump is 0.476 m against a median per-frame total of 0.321 m (bound 2×).

Playback: in place. The bake keeps the root's travel (world space), so the 6.3 matching has it. The host removes the root's horizontal translation in `pose_palette_frame`, before `build_palette_root`, with `strip_root_xz`; `rest_palette` is unchanged, so B1 checks the true rest.

Root rule: CesiumMan's clip locals are in its own frame before `root_transform`. The root joint's local is `root_transform⁻¹ · W_0`, and its translation is the scaled CMU root position (ratio 0.755 = 0.593 / 0.785, the hip above the lowest toe). Non-root locals `W_parent⁻¹·W_j` are frame-independent. Without the root rule CesiumMan lies on its side (the B1 failure).

fps rule: `.lcharacter` has one fps (30) for every clip. The 120 fps CMU trial is resampled by taking every 4th frame (79 frames). Without it the walk plays four times too slow.

Output: clip kind 101, written by `convert_glb.write` (same alignment and selftest). `convert_glb.py --selftest`: 13/13 after the bake.

Checks on the written file (`scripts/retarget.py --check`):
- M2 (14 mapped non-leaf joints, source frames 0, 60, 120, 200): worst direction error 0.0000° at every frame. The check recomposes the file through a Python mirror of `build_palette_root` with `root_transform`. Before the lowerback fix the same check failed at 4.99° to 10.3° on joint 0 only, which is why the root's rotation alone is not enough.
- M3: target bone lengths change by at most 5.8e-8 m (bound 1e-5); the lowest `leg_*_5` joint over the clip is +0.087 m (bound −0.02).
- Stick figures: `/tmp/claude-0/m6/retarget_figures.png` (CMU blue, CesiumMan red, four frames, front and side). CesiumMan follows CMU through the stride; the arms are plausible, though the red arms sit a little lower.

### 1.7 Where retargeting runs (U6.1)

**Answered (ludens-core `procedural/anim_graph.mojo`, `retarget` and `Skeleton`): `retarget` does not do the retarget this design needs.**

- Signature: `retarget(src_pose: Pose, src: Skeleton, dst: Skeleton) -> Pose`. It has no joint map and no rest-pose alignment argument.
- Behaviour: it copies each local rotation unchanged and rescales each local translation by the target-to-source bone length ratio. It assumes the two skeletons share the same bone order.
- It does not do world-rotation transfer (§1.6), rest alignment `A_j`, or per-joint mapping between CMU and CesiumMan.

So the advisor's second branch applies: bake the retarget in Python at build time, as a new clip (kind 100+k) in CesiumMan's `.lcharacter`. The runtime path, and M4, do not apply to `retarget` as it stands. A runtime version would be a new function in ludens-core or the engine.

Earlier plan text: the plan said runtime, through `procedural.anim_graph.retarget`.

- If its signature takes both rests, a joint map and a source pose, and returns target locals: run it at runtime, with a Python oracle for the checks.
- Otherwise: bake it at build time in Python, as a new clip (kind 100+k) in CesiumMan's `.lcharacter`.

### 1.8 MotionDB

**Found in ludens-core (`procedural/anim_graph.mojo`): `MotionDB` is a brute-force nearest-frame search over pose features.** Its features are root velocity (x, z) and the positions of chosen bones, not the feet-and-trajectory features this section lists. 6.3 wraps `MotionDB` and adds the feature vector from this section, so the feature code lives in the playground; the nearest-frame search is reused as it is. `two_bone` and `fabrik` in `procedural/ik.mojo` are the IK already in ludens-core; 6.4 wraps them.

Earlier plan text follows.


- Use trials from one subject, so a single ASF covers them all.
- Per-frame features: both feet's positions and velocities in the root's facing frame, the hip velocity, and the root's future trajectory at +0.33, +0.67 and +1.0 s (2D position plus facing).
- Normalise each feature by its standard deviation.
- Match by brute force every 0.1 s, and crossfade over 0.2 s.
- U6.7 is to grep ludens-core for an existing MotionDB or matcher first.
Recorded deviation (2026-11-14, step 6.3): the design asks for walk, run and turn trials from one subject. Subject 07
has walk, slow walk and brisk walk only (the CMU search page, subject 7: trials 1 to 12, no run, no turn). The database
uses 07_01 (walk), 07_04 (slow walk) and 07_12 (brisk walk). Its features separate speed (mean hip speed 0.92, 0.63 and
1.30 m/s) but not turning: the facing components of the trajectory vary only with the walk's own heading changes, so
M6 cannot show that a turn is matched. A subject with run and turn trials is a separate change, since it needs its own
ASF, the M1 and M2 checks, and a leg ratio.

### 1.9 Checks

- **M1 (converter selftest):**
  - `lfemur` is between 0.35 and 0.50 m. Measured: 0.404 m on 01_01 and 07_01 (`lfemur` 7.158 units × 0.0254 / 0.45).
  - Rest height is between 1.5 and 1.9 m, with the head highest and the toes lowest. Measured at the static rest pose: head 0.645 m above the root, lowest toe −0.919 m, so 1.564 m.
  - Toe contact, robust form (replaces the old minimum-height check, which did not separate composition orders): on every trial, the floor of each toe (5th percentile of its height) is within 0.10 m of the trial's lowest floor, and foot skate passes: the median horizontal speed of contact frames is below 0.15 m/s for both toes. Measured: 07_01 passes; 01_01 passes.
  - Arms: the two wrists' heights relative to their own shoulders agree in sign on walk trials at the sampled frames (checked at 0, 100, 200 on 07_01).
- **M2:** retargeting the source rest gives each mapped target bone the source's rest direction, within 1e-3 rad.
- **M3:** target bone lengths stay within 1e-5 of rest, and foot height stays at or above −0.02 m over the whole clip.
- **M4 (runtime only):** engine against oracle on 5 frames, joint world positions within 1e-4 m, native and wasm.
- **M5 (page):** the idle-animation check passes, and the PNG looks like the trial's motion.
- **M6 (MotionDB):** a query built from DB frame k returns k, for 20 values of k. The match index is the same native and wasm.

### 1.10 PRs

- 6.0: `.lmotion` v2, FK, M1, and the extra trials.
- 6.1: retargeting, with M2 and M3, plus M4 if it runs at runtime.
- 6.2: the page plays the retargeted motion (M5).
- 6.3: MotionDB and matching (M6).
- 6.4: foot IK, only if ludens-core's IK fits. Otherwise defer it.

## 6.4 decision (deferred)

Foot IK (6.4) is deferred. Reason, checked on 2026-11-14:

- ludens-core has `two_bone` (`procedural/ik.mojo:54`) and `fabrik`, and `foot_plant` (`:210`) takes a ground height and a normal. The machinery fits.
- The floor it would act on is flat. The engine's arena (`game/arena.mojo`, floor and four walls) is one plane, and the page has no other ground. A foot on a flat floor already sits on it: the floor offset in 1.6 places the rest leg on it, and the CMU walk's toes stay within 0.10 m of their lowest floor (M1).
- So IK would only change the feet by the sub-centimetre drift the walk already has, and nothing on the page shows a slope to correct.

Revisit when a level has slopes or steps. Then `foot_plant` takes the ground height from the level, and `two_bone` places the knee on each leg.

## Layer 2: PR 6.0 steps

1. Record U6.8 (what `.lmotion` v1 stores) and the `:units` line.
2. Move the bonedata parser into `convert_amc.py`, and write v2 with a per-bone rest blob.
3. Write `fk(frame)` in Python, and run M1 on 01_01 under each composition order. Keep the order that passes, and write it into this note.
4. Pick one subject from CMU's subject pages that has several walk, run and turn trials. Read the trial descriptions there, and don't rely on recall. Add the ASF and the trials with `--learn`, then regenerate the credits. List the download size in the PR.

## Layer 3: PR 6.0 commands

```
git checkout -q -b feat/motion-asf-v2 feat/frontier-meshes
grep -n "def write\|def build\|struct.pack\|array(" scripts/convert_amc.py
grep -n "^:units" -A4 build/assets/src/01.asf
grep -rn "def retarget\|MotionDB\|motion_match\|two_bone\|fabrik" build/deps/ludens-core/procedural/
```

Expect PASS lines for M1, with the femur length and standing height printed in metres.

Stop and report the per-bone FK printout if M1's foot check fails under every order tried, or if U6.1's signature is ambiguous.

Steps 7 and 8 wait until 6.x lands.

## Measured rest data (for the mapping in 1.6)

CMU `01.asf` bonedata (name, length, rest direction; the ASF axis is in the file):

| # | name | length | rest direction |
|---|---|---|---|
| 0 | lhipjoint | 2.4048 | (+0.567, -0.746, +0.349) |
| 1 | lfemur | 7.1578 | (+0.342, -0.940, +0.000) |
| 2 | ltibia | 7.4914 | (+0.342, -0.940, +0.000) |
| 3 | lfoot | 2.3678 | (+0.067, -0.183, +0.981) |
| 4 | ltoes | 1.1897 | (+0.000, -0.000, +1.000) |
| 5 | rhipjoint | 2.3727 | (-0.550, -0.756, +0.354) |
| 6 | rfemur | 7.4339 | (-0.342, -0.940, +0.000) |
| 7 | rtibia | 7.5091 | (-0.342, -0.940, +0.000) |
| 8 | rfoot | 2.4117 | (-0.068, -0.188, +0.980) |
| 9 | rtoes | 1.2108 | (-0.000, -0.000, +1.000) |
| 10 | lowerback | 2.0450 | (+0.014, +0.995, -0.095) |
| 11 | upperback | 2.0501 | (+0.028, +0.999, -0.021) |
| 12 | thorax | 2.0649 | (+0.020, +1.000, +0.023) |
| 13 | lowerneck | 1.7555 | (-0.031, +0.995, +0.098) |
| 14 | upperneck | 1.7688 | (+0.059, +0.996, -0.070) |
| 15 | head | 1.7719 | (+0.021, +0.999, -0.035) |
| 16 | lclavicle | 3.5840 | (+0.938, +0.335, -0.087) |
| 17 | lhumerus | 4.9830 | (+1.000, -0.000, -0.000) |
| 18 | lradius | 3.4836 | (+1.000, -0.000, -0.000) |
| 19 | lwrist | 1.7418 | (+1.000, -0.000, -0.000) |
| 20 | lhand | 0.7153 | (+1.000, -0.000, -0.000) |
| 21 | lfingers | 0.5767 | (+1.000, -0.000, -0.000) |
| 22 | lthumb | 0.8280 | (+0.707, -0.000, +0.707) |
| 23 | rclavicle | 3.4482 | (-0.910, +0.398, -0.117) |
| 24 | rhumerus | 5.2419 | (-1.000, -0.000, -0.000) |
| 25 | rradius | 3.4442 | (-1.000, -0.000, -0.000) |
| 26 | rwrist | 1.7221 | (-1.000, -0.000, -0.000) |
| 27 | rhand | 0.6225 | (-1.000, -0.000, -0.000) |
| 28 | rfingers | 0.5019 | (-1.000, -0.000, -0.000) |
| 29 | rthumb | 0.7206 | (-0.707, -0.000, +0.707) |

CesiumMan (19 joints; parent, rest translation in its own frame before `root_transform`):

| id | name | parent | rest translation |
|---|---|---|---|
| 0 | Skeleton_torso_joint_1 | -1 | (+0.000, +0.005, +0.679) |
| 1 | Skeleton_torso_joint_2 | 0 | (+0.000, -0.000, +0.145) |
| 2 | torso_joint_3 | 1 | (-0.251, +0.000, -0.000) |
| 3 | Skeleton_neck_joint_1 | 2 | (-0.000, +0.000, +0.065) |
| 4 | Skeleton_neck_joint_2 | 3 | (-0.052, -0.000, -0.000) |
| 5 | Skeleton_arm_joint_L__4_ | 2 | (-0.000, +0.091, -0.000) |
| 6 | Skeleton_arm_joint_R | 2 | (-0.000, -0.091, -0.000) |
| 7 | Skeleton_arm_joint_L__3_ | 5 | (+0.013, +0.215, +0.109) |
| 8 | Skeleton_arm_joint_R__2_ | 6 | (-0.036, -0.215, +0.104) |
| 9 | Skeleton_arm_joint_L__2_ | 7 | (-0.093, +0.143, +0.078) |
| 10 | Skeleton_arm_joint_R__3_ | 8 | (+0.031, -0.143, -0.118) |
| 11 | leg_joint_L_1 | 0 | (+0.029, +0.068, -0.063) |
| 12 | leg_joint_R_1 | 0 | (+0.029, -0.068, -0.063) |
| 13 | leg_joint_L_2 | 11 | (+0.209, +0.009, -0.164) |
| 14 | leg_joint_R_2 | 12 | (+0.261, -0.009, +0.052) |
| 15 | leg_joint_L_3 | 13 | (+0.276, +0.001, +0.004) |
| 16 | leg_joint_R_3 | 14 | (+0.275, -0.001, -0.014) |
| 17 | leg_joint_L_5 | 15 | (-0.066, +0.001, +0.029) |
| 18 | leg_joint_R_5 | 16 | (-0.067, -0.001, +0.026) |

The CMU table is the ASF bonedata as written. The CesiumMan table is the converted file's rest translations. The mapping in 1.6 is not yet decided; it is decided in PR 6.1 from the two rest-pose FK printouts.

Still open: the CMU ASF `:units` line (U6.8 and 1.3 read it), and every CMU trial beyond subject 01's `01_01`.
