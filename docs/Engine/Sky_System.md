# Realtime Sky System

NeuraLink draws a procedural, physically based sky on the GPU with **Metal**.
The sky follows the device's **real clock and place**. The sun rises and sets
at the real times for where the user is. The moon stands where it really is,
with tonight's phase, and shows by day too. The stars turn through the night,
and the real constellations are among them. The sky's colour is light
scattered by a model of the real atmosphere, so the sunset glow sits on the
sun's side and twilight lingers after it. The same sky lights the character,
the terrain and the 3D environments, and its wind moves the character's hair.
Rain comes and goes on its own procedural schedule. It is not a forecast.

---

## Gallery

These are renders from the app's own renderer, over Antananarivo, regenerated
by `SkySnapshots` (see [Checking the sky](#checking-the-sky)).

### A day, toward the sun

| Before dawn | Sunrise | Morning | Noon |
|:---:|:---:|:---:|:---:|
| <img src="../Assets/Sky/day-before-dawn.png" alt="Before dawn" width="200" /> | <img src="../Assets/Sky/day-sunrise.png" alt="Sunrise" width="200" /> | <img src="../Assets/Sky/day-morning.png" alt="Morning" width="200" /> | <img src="../Assets/Sky/day-noon.png" alt="Noon" width="200" /> |
| **Afternoon** | **Sunset** | **Dusk** | **Night, toward the moon** |
| <img src="../Assets/Sky/day-afternoon.png" alt="Afternoon" width="200" /> | <img src="../Assets/Sky/day-sunset.png" alt="Sunset" width="200" /> | <img src="../Assets/Sky/day-dusk.png" alt="Dusk" width="200" /> | <img src="../Assets/Sky/day-night.png" alt="Night, toward the moon" width="200" /> |

### The light on the face through the same day

The sky lights the character too. By day the key light is the sun's colour
through the air, and after dusk it blends into the moon's cool light (or the
night sky's). The fill and the rim take the sky's colour on their side. The
sky's own light is MToon's GI (see
[The sky's own light](#the-skys-own-light--skyambient)). Below is the default
character's face, close, at the same moments, with the camera facing the
sunset as it does in the app:

| Before dawn | Sunrise | Morning | Noon |
|:---:|:---:|:---:|:---:|
| <img src="../Assets/Sky/face-before-dawn.png" alt="The face before dawn" width="200" /> | <img src="../Assets/Sky/face-sunrise.png" alt="The face at sunrise" width="200" /> | <img src="../Assets/Sky/face-morning.png" alt="The face in the morning" width="200" /> | <img src="../Assets/Sky/face-noon.png" alt="The face at noon" width="200" /> |
| **Afternoon** | **Sunset** | **Dusk** | **Night** |
| <img src="../Assets/Sky/face-afternoon.png" alt="The face in the afternoon" width="200" /> | <img src="../Assets/Sky/face-sunset.png" alt="The face at sunset" width="200" /> | <img src="../Assets/Sky/face-dusk.png" alt="The face at dusk" width="200" /> | <img src="../Assets/Sky/face-night.png" alt="The face at night" width="200" /> |

*Cool and dim before dawn. Warm as the sun comes up behind the camera. A
crisp toon shadow under the morning sun, and bright at noon. Orange as the sun
sets beside the character, purple in the twilight, and grey-blue under the
night sky, still readable.*

### The moon through a month

Each picture is the moon as it stands over Antananarivo that night, at its
highest in a dark sky (the sun 8° down). Its lit side points to the sun below
the horizon, so near the tropics the crescents lie almost on their backs. The
moon shows by day too, with the sky's blue showing through its unlit part.

| Waxing crescent | First quarter | Waxing gibbous | Full |
|:---:|:---:|:---:|:---:|
| <img src="../Assets/Sky/moon-waxing-crescent.png" alt="Waxing crescent" width="200" /> | <img src="../Assets/Sky/moon-first-quarter.png" alt="First quarter" width="200" /> | <img src="../Assets/Sky/moon-waxing-gibbous.png" alt="Waxing gibbous" width="200" /> | <img src="../Assets/Sky/moon-full.png" alt="Full moon" width="200" /> |
| **Waning gibbous** | **Last quarter** | **Waning crescent** | **By day** |
| <img src="../Assets/Sky/moon-waning-gibbous.png" alt="Waning gibbous" width="200" /> | <img src="../Assets/Sky/moon-last-quarter.png" alt="Last quarter" width="200" /> | <img src="../Assets/Sky/moon-waning-crescent.png" alt="Waning crescent" width="200" /> | <img src="../Assets/Sky/moon-by-day.png" alt="The moon by day" width="200" /> |

### The Southern Cross

| The Southern Cross |
|:---:|
| <img src="../Assets/Sky/stars-southern-cross.png" alt="The Southern Cross and the Pointers" width="200" /> |

*High in the south on a moonless evening: the Cross upright at upper right,
orange γ Crucis at its head and α Crucis at its foot, and the Pointers
(α and β Centauri) the bright pair at left, among the faint procedural field.*

### In the app

<p align="center">
  <img src="../Assets/Environments/sunrise.png" alt="Sunrise sky" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/early-morning.png" alt="Early morning sky" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/morning.png" alt="Morning sky" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/afternoon-sun.png" alt="Afternoon sun sky" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/evening-sun-1.png" alt="Evening sky, earlier" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/evening-sun-2.png" alt="Evening sky, later" width="280" style="margin:6px;" />
</p>
<p align="center">
  <img src="../Assets/Environments/sunset.png" alt="Sunset sky" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/early-night.png" alt="Early night sky" width="280" style="margin:6px;" />
  <img src="../Assets/Environments/night.png" alt="Night sky" width="280" style="margin:6px;" />
</p>

*From left to right: sunrise · early morning · morning · afternoon · evening, earlier · evening, later · sunset · early night · night*

---

## When and where — `SkyTimeProvider` and `SkyLocation`

`SkyTimeProvider` gives the sky its instant (`now`, which tests can replace to
freeze it) and its time zone (`.autoupdatingCurrent`, so the sky follows the
user when they travel). `SkyTimeProvider.fromEnvironment` reads the `NL_SKY_*`
overrides (see [Checking the sky](#checking-the-sky)).

The place comes from the time zone, so no location permission is needed.
`SkyLocation(timeZone:)` looks up the zone's name in `sky_zones.txt`. The
table has one row per zone of the tz database's `zone.tab`, plus the older
names iOS still reports for some zones (`Asia/Calcutta`, `Europe/Kiev`…).
`Indian/Antananarivo` gives Antananarivo, 18.92° S, 47.52° E, wherever on the
island the user is. Sunrise and sunset are right to within a few minutes near
the capital and only estimates elsewhere: the west coast is 3–4° of longitude
away, so its sun sets about a quarter of an hour later. The app has no
location input that could narrow this down. A zone the table doesn't know
(`GMT`, a fixed offset) gets the equator, at the longitude its UTC offset
stands for.

---

## Sky environment — `SkyEnvironment`

`SkyEnvironment.resolve(at:location:sky:)` (`SkyColorPalette.swift`) is the
heart of the system. It works out where the sun and moon stand
(`SkyBodies`), then the colours and lights for that (`resolve(_:sky:)`).
`sky` is the sky's own light from the previous sky-view update, when one is
available (see [The sky's own light](#the-skys-own-light--skyambient)).

### The sun, the moon and the stars — `SkyEphemeris`, `SkyBodies`

All positions are computed from the instant itself, in double precision,
following Meeus, *Astronomical Algorithms*:

- **Sun.** The low-precision solar position of ch. 25, the one the NOAA
  calculator uses (about 0.01°). Sunrise and sunset over Antananarivo land
  within two minutes of NOAA's on the solstices and equinoxes.
- **Moon.** The largest terms of the lunar theory of ch. 47 (about 0.1°), as
  seen from the Earth's surface rather than its centre (up to 1° lower). Its
  lit fraction comes from the angle between it and the sun. Its light comes
  from that phase (Allen's lunar magnitude), so a quarter moon gives about a
  tenth of a full moon's light.
- **Stars.** The catalogue's J2000 positions, precessed to today (0.36° by
  2026) and turned by local sidereal time (ch. 12) and latitude. They rise in
  the east, the celestial pole stays at the latitude's height, and from
  Madagascar the Southern Cross circles the south pole.

**The compass.** The scene is +Y up with the camera on +Z, looking toward
−Z past the character. A portrait phone sees only about 15° to either side of
straight ahead, and the sun and moon spend most of their time high or off to
the sides. So the compass is turned for them: the camera looks toward the
day's sunset. The sun comes down beside the character every evening, in view
for its last hour, and the moons that set in the west go down there too
(crescent to first quarter in the evening, full at dawn). The sunset point is
put 10° to the side the setting sun comes down from (`SkyBodies.sunsetBearing`:
right of the character in the southern hemisphere, left in the northern), so
the character doesn't hide it. The compass follows the sun's declination and
turns under half a degree a day. It only ever turns about the vertical and is
never mirrored, so the sun still rises in the east, behind the camera. Between
the tropics the noon sun can pass a little to the other side of the zenith (in
Antananarivo from late November to mid-January).

| Antananarivo | Sunrise | Sunset | Noon sun |
|---|---|---|---|
| 21 June | 06:22 | 17:21 | 48° up, north |
| 21 December | 05:10 | 18:26 | 85° up, just south |

### Transition factors

Two smoothstep-based factors drive the colour, light and cloud curves:

| Factor | Formula | Meaning |
|--------|---------|---------|
| `dayFactor` | `skySmooth(-0.15, 0.20, sunDir.y)` | 0 = full night, 1 = full day (from about 12° up) |
| `sunsetFactor` | `clamp(1 – abs(sunDir.y) × 3.5, 0, 1) × (sunDir.y > −0.1 ? 1 : 0)` | Peaks at sunrise and sunset, 0 at mid-day and night |

`skySmooth` is a classic **smoothstep** (`t² (3−2t)`), which gives a smooth
S-curve instead of a harsh linear ramp.

### The atmosphere — `SkyAtmosphere`

The sky's colour is sunlight (and moonlight) scattered by the air, following
Hillaire's model ("A Scalable and Production Ready Sky and Atmosphere
Rendering Technique", 2020), the one Unreal's sky uses. Three things in the
air shape the light:

- The air scatters blue most (Rayleigh).
- Fine aerosols scatter all colours forward around the sun (Mie, g = 0.8),
  which makes the glow.
- The ozone layer, densest 25 km up, takes out some red and green, which keeps
  the twilight zenith blue.

Each of them thins with height. The GPU keeps three lookup tables
(`SkyAtmosphere.metal`, all `rgba16Float`):

| Table | Size | Holds | Built |
|---|---|---|---|
| Transmittance | 256×64 | How much light gets from any height, along any direction, to space | Once |
| Multiple scattering | 32×32 | Light scattered more than once, which fills the shadowed side of the sky and keeps twilight from going black | Once |
| Sky view | 192×108 | The whole sky seen from the ground, lit by the sun and the moon; in alpha, the haze in front of the low clouds | When the sun or moon moves more than 0.1° (about every 25 s) |

The sky's fragment shader then only looks up the view. Several effects follow
from the model, and none of them is hand-keyed:

- The sky whitens toward the horizon and brightens around the sun.
- At sunset the glow sits on the sun's side, and the opposite sky turns pink
  over the blue band of the Earth's own shadow.
- After sunset an orange band stays where the sun went down, while the sky
  above deepens through purple to blue.

**The eye's adaptation.** Twilight is a hundred to ten thousand times darker
than day, so the sky is brightened as it darkens, the way an eye adapts.
`SkyAtmosphere.exposure` follows the sky the eye looks at: the glow low toward
the sun plus the sky overhead, against the sky with the sun 30° up. The
exposure holds steady from mid-morning to noon and dips a little at sunrise and
sunset, when the glow by the low sun is brightest. Through twilight it makes
up for 80% of the darkening, so the sky still deepens. Six degrees after
sunset the sky is still lit, about a third as bright as by day. Adaptation
stops at 0.03% of the day's sky (`darkestAdapted`), around 10° down, where the
last of the twilight fades into the night.

**The night.** A physical sky goes black after twilight. Under it, the night's
own glow (airglow and starlight) keeps the night palette, deep blue and a
little brighter overhead (`nightGlowLow` `#0d1321`, `nightGlowHigh` `#1c2331`).
It comes in as the sun goes from 1° to 9° below the horizon. The moon lights
the air like a weak sun, so a full moon brings a faint blue sky around and
above it (`SkyRenderer.moonSkyLight`, scaled by its brightness).

**The grade.** The table holds light, not colours. The shader shows it through
a soft shoulder (`1 − e^−x`), so the bright sky by the sun rolls off instead of
clipping, and lifts its saturation a little (×1.25) to match the toon-shaded
character in front of it.

**The sun's colour.** `SkyAtmosphere.lightColor` is the sunlight left after
the air it crosses, scaled so its brightest channel is 1: white-gold
overhead, orange low, red on the horizon. The sun's disc takes the colour for
the sun's height. It is drawn over the glow and less deep, so a red sun still
shows against it. The key light takes the colour for its own height, never
lower than its 7° floor.

### Lighting the character

The resolved `SkyEnvironment` also drives the three-point light rig and the
ambient light for the VRM character, so it always looks natural against the
sky. `VRMRenderer.applySkyLighting` sets them every frame: light 0 is the key,
light 1 the fill, light 2 the rim, and the ambient is the sky's light under
rain's overcast.

| Light | Source | Day | Night |
|-------|--------|-----|-------|
| **Key** | `SkyKeyLight`: sun by day, moon (or the sky above) by night, turned to the camera's side | The sunlight through the air (white-gold high, orange low), intensity up to 1.2 | Cool blue `#8c99d9`, intensity 0.42–0.58 |
| **Fill** | Opposite the sun's side, from above and in front (`−sun.x × 0.6, 0.5, 0.8`) | The sky's colour on that side (`SkyAmbient`), at the luminance of a sky-blue fill, intensity 0.38 | The same, at the luminance of a dim cool blue, intensity 0.20 |
| **Rim** | Above and behind the character; the key light itself while that stands behind it | The sky behind the character, as the camera sees it; the key's colour while the key is behind | The same |
| **Ambient** | The whole sky and the ground under it (`SkyAmbient`), as MToon's GI | Blue from above, the sand's warmth from below | Cool, from the night's glow and the moonlit sky |

> **The night key light.** At night `dayFactor` = 0 and the key light turns
> into a cool-blue night light. It comes from the moon while the moon is up and
> more than a crescent, and from high in the sky otherwise. Its intensity
> follows the moon's brightness, from 0.42 on a moonless night to 0.58 under a
> high full moon, so the character stays readable without breaking the
> night-sky illusion.

**One key light, no flip.** `SkyEnvironment.keyLight` is the only light that
the terrain, its shadows (the character's among them) and the 3D environments
follow. Through twilight it travels from the sun to the night light *over the
sky*, rather than jumping to the opposite horizon when the sun crosses it.
The direction changes hands between 6° below and 5° above the horizon, so
shadows shorten and turn instead of swinging across in one frame. It never
drops below about 7° of elevation (`SkyKeyLight.minimumElevation`), where a
grazing light would throw endless shadows. Its largest turn between two
consecutive minutes is under 8°. Its shadow softness goes from 1.5 at night to
2.5 by day.

**The character's face stays lit.** Facing the sunset puts the afternoon and
evening sun behind the character. The character takes the key light mirrored
onto the camera's side (`SkyKeyLight.avatarDirection`), so the face is lit
warm while the sun goes down beside it, and its self-shadow follows that
light. The real light rims the character instead: while it stands behind, the
rim light takes its direction and colour. The rim stays modest, because MToon
shares its lights out and a strong back light would take the face's share. The
character's shadow on the ground still falls from the real key light
(`keyLight.direction`, not the mirrored one): from the sun by day, and from the
night light or the twilight blend between them otherwise.

### The sky's own light — `SkyAmbient`

MToon's GI is the spec's SH probe: `gi = lerp(SH(normal), SH average,
giEqualizationFactor)`. Here that probe is the sky itself, at the lowest order
that has a direction (L1 spherical harmonics, convolved with the cosine). Each
time the sky view is lit again, `sky_ambient_sh` (one threadgroup of 256) sums
the sky *as shown* (graded, with the night's glow in) into a mean and a
gradient along each axis:

```
mean     = 1/4π ∫ L dω
gradient = 1/2π ∫ L ω dω          GI(n) = mean + gradient · n
```

The GPU sums the upper hemisphere. `SkyRenderer.collectSkyAmbient` reads the
result back a frame or so later, once its command buffer has finished, and
adds the ground: a plane of the terrain's sand (`SkyRenderer.groundAlbedo`)
lit by that sky and by the sun (`sunGroundLight`). A uniform lower hemisphere
adds half its light to the mean and takes half off the gradient along +Y.

The character takes the sky's colour and the direction it comes from, but not
its brightness. `SkyAmbient.shaped` scales it to the luminance of the scene's
ambient curve (`ambientColor`: a moonlit floor at night, 0.18 grey at noon),
which keeps a toon-shaded face readable at night. It keeps 80% of the colour
and limits the gradient, so no side falls below 40% of the mean. The result is
blue from above at noon, orange from the sun's side at dusk, and cool at
night. Rain drains and darkens it the way it does the sky (`overcast`: 70% of
the colour drained at full rain, 28% darker). Until the first sum is back, the
character gets a plain hemisphere: one colour, 35% brighter from above and 35%
darker from below. The `Uniforms` carry the mean in `ambientColor` and the
gradient in `ambientAlongX/Y/Z` (offsets 432, 448 and 464, 480 bytes in all),
and both the main and the outline passes read them (`mtoonAmbientAlong`).

The fill and the rim take their colour from the same light: the sky on the
fill's side, and the sky behind the character. The fill stays strong. MToon
averages its lights by strength, so without the fill the key's share grows and
the lit half of a face at noon blows out.

**The ground and the environments read it too.** The terrain colours its
sunlit part with half the key light's hue: white-gold by day, orange at
sunset, cool under the moon. Where the sun doesn't reach, it takes a quarter
of the sky's hue from above; more would drain the sand's warmth. Outdoor 3D
environments keep their palette's brightness but take 60% of the sky's hue
along each surface's normal. Interiors (`EnvironmentOption.isInterior`) keep
their own palette.

### Wind — `SkyWind`

A light breeze moves the hair and clothes. It blows the way the low clouds
drift, and its direction wanders up to about ±37° over minutes. Its strength
comes in slow, uneven gusts that never quite stop. The breeze is stronger by
day, when the clouds move faster, and in the rain (up to 1.8×). It enters
`SpringBoneSolver` as one term beside gravity:

```
nextTail += wind · dt · dragForce
```

That is the spec's own drag, slowing a tail relative to the moving air rather
than to still air. Stiff chains barely move and light hair sways. With the wind
at zero, the step is exactly the spec's. `VRMRenderer.springBoneWind` turns the
wind into the model's own space. A VRM 0.x model is drawn turned 180°, so its
wind is turned back, or its hair would blow against the clouds. The wind is
NeuraLink's own extension. It is on by default for the bundled characters,
whose springs it was tuned on, and opt-in for imported ones. Both switches are
in User Profile → Environment Settings (*Wind in Hair and Clothes*, *Wind for
Imported Characters*).

---

## GPU uniforms — `SkyUniformsData`

`SkyUniformsData` is a **256-byte flat struct** shared between Swift and Metal.
The layout is fixed and must match `SkyUniforms` in `SkyShader.metal` exactly
(`SkySystemTests` checks the stride):

| Field | Bytes | Offset | Description |
|-------|-------|--------|-------------|
| `invViewProjection` | 64 | 0 | Camera inverse VP matrix, which maps NDC to a world ray |
| `sunDirectionAndIntensity` | 16 | 64 | `xyz` = toward-sun unit vector · `w` = key intensity, darkened by rain (not read by the shader) |
| `sunColorAndSize` | 16 | 80 | `xyz` = disc colour · `w` = disc exponent (300 = tight) |
| `nightGlowLow` | 16 | 96 | `xyz` = the night's glow at the horizon (weighted by how dark it is) · `w` = rain |
| `nightGlowHigh` | 16 | 112 | `xyz` = the night's glow at the zenith |
| `cloudParams` | 16 | 128 | `x` = elapsed time · `y` = scroll speed · `z` = coverage · `w` = star visibility (both after rain) |
| `moonDirectionAndPhase` | 16 | 144 | `xyz` = toward-moon unit vector · `w` = lit fraction |
| `bodyParams` | 16 | 160 | `x` = moon angular radius (radians) · `z` = moon brightness against full |
| `starRotation` | 48 | 176 | `float3x3`: star catalogue (J2000 equatorial) → world; its transpose takes a view ray back into the stars' frame |
| `moonEdges` | 16 | 224 | cos of the moon's angular radius × 1.48 (where it starts hiding stars), × 1 (where it hides them all), × 1.03 and × 0.97 (its disc's soft edge). These are the same for every pixel, so they are worked out once on the CPU |
| `detail` | 16 | 240 | `x` = cloud layers drawn: 2, or 1 on a hot phone (see [Cost](#cost)) |

The buffer is allocated once with `.storageModeShared` (CPU-visible Metal
memory) and updated every frame with `copyMemory`.

---

## Sky renderer — `SkyRenderer`

`SkyRenderer` owns the Metal pipelines and the atmosphere's tables, and works
in three steps.

### Per-frame update

```swift
func update(deltaTime: Float)
```

- Advances `cloudTime`, the clock of the cloud animation and the wind's gusts.
- Calls `SkyEnvironment.resolve(at: timeProvider.now(), location: timeProvider.location, sky: skyAmbient)` to get a fresh environment.

`VRMMetalState` calls it each tick through `VRMRenderer.updateSky`, then
`updateRain` and `applySkyLighting`.

### The atmosphere's tables, before the render pass

```swift
func encodeAtmosphere(commandBuffer: MTLCommandBuffer)
```

The first time, this builds the transmittance and multiple-scattering tables
and the clouds' noise (256², `r16Float`, whose mipmaps are then made by a
blit). After that it lights the sky view again whenever the sun or the moon has
moved 0.1°, or the moon's light has changed. The sun's light is scaled by the
eye's exposure for its height (`sunSkyLight` × `SkyAtmosphere.exposure`). The
sky view's alpha holds the haze in front of the clouds (see [Clouds](#clouds)).
Each new sky view is also summed into the sky's light (`sky_ambient_sh`),
which comes back as `skyAmbient` on a later frame (`collectSkyAmbient`) and
goes into the next `SkyEnvironment`. `VRMRenderer` encodes it after the shadow
passes and before the main render pass, on every frame path. Until the sky
view has been lit once, the sky isn't drawn.

### Render-thread preparation

```swift
func prepareForEncoding(viewProjection: simd_float4x4)
```

Packs the latest `SkyEnvironment` into `SkyUniformsData`, with rain applied,
and copies it into the shared Metal buffer. Rain raises the coverage toward
0.92 and dims the stars by up to 95%. The same call decides whether the
catalogue stars are drawn. `VRMRenderer.drawSky` calls it immediately before
`encode`.

### Draw call

```swift
func encode(encoder: MTLRenderCommandEncoder)
```

Issues a **single 3-vertex draw**: a fullscreen triangle. Its textures are the
sky-view table, the transmittance table and the clouds' noise, and its bytes
are the sky view's last lights (`SkyViewParams`) and the atmosphere's
constants (`SkyAtmosphereParams`), which the clouds need. No vertex buffer is
needed, because the vertex shader hardcodes the positions and picks one by
`vertex_id`. The vertex shader also works out the world-space view ray at each
corner through the inverse view-projection matrix. That ray is affine in
screen space for a perspective or orthographic camera, so interpolating it is
exact, and the fragment only normalises it. The sky is the first thing drawn
in the pass, with depth **always pass / no write**, so everything drawn after
it covers it.

While stars are out, a second draw adds the bright-star catalogue on top. It
is one instanced 4-vertex strip per star (about 300), blended additively,
reading the clouds' noise to hide the stars behind clouds. It is skipped by
day, and under an orthographic camera, which has no sky to place them in.
Both draws sit in the `SkyBackground` debug group.

---

## Sky shader — `SkyShader.metal`

The sky is two draws. The fullscreen fragment shader (`sky_fragment`) takes the
**world-space view ray** interpolated from the vertices, then composites
layers 1–6 from back to front. The catalogue stars (7) are a second, instanced
draw on top, through their own `sky_star_vertex` / `sky_star_fragment`.

### Layer stack (back to front)

```
┌─────────────────────────────────────────────┐
│  1. Atmosphere — sky-view   (always)        │
│  2. The Night's Glow        (after sunset)  │
│  3. Faint Stars             (night only)    │
│  4. Clouds — two lit layers                 │
│  5. Sun Disc + Bloom        (above horizon) │
│  6. Moon — phase-lit sphere (when it's up)  │
│  7. Bright Stars — sprites  (second draw)   │
└─────────────────────────────────────────────┘
```

#### Atmosphere

```metal
float4 behind = skyView.sample(around, skyViewUV(viewDir));   // a = the haze before the clouds
float3 colour = skyAtmosphere(behind.rgb, viewDir, sky);      // the grade + the night's glow
```

The table maps the view ray by azimuth around the horizon, and from straight
down to straight up, squeezed toward the horizon where the sky changes
fastest. The sky is shown through the grade (a soft shoulder and a little more
saturation). Below the horizon the table holds the haze of the air in front of
the ground.

#### The night's glow

The night palette, from horizon to zenith, is weighted by how far the sun is
down and added under the twilight, darkening to 22% below the horizon. After
the clouds, rain drains the colour and darkens the sky and its clouds
(`skyOvercast`: up to 70% toward grey, 28% darker), keeping the brightness
otherwise, so a rainy night stays night.

#### Faint stars

The faint stars are procedural, but in the stars' own frame: the view ray is
turned back by `transpose(starRotation)`, so they turn with the sky. They sit
on a grid of 80×80 cells on each face of a cube, at most one star per cell and
kept inside it. The chance of a star follows the cell's solid angle, so the
cube's corners are no denser than its faces. Each star is a round dot of a set
angular size (0.09–0.16°). They are drawn only above the horizon and only
while `starVis` (`cloudParams.w`) is above zero. Star visibility rises as the
sun goes down and reaches 1 only when the sun is about 21° below the horizon.
The moon hides the stars behind it, and its glare washes them out (more near
it, and more the fuller it is).

#### Clouds

There are two layers. Each is a shell around the planet, so the clouds run on
to a real horizon and get smaller with distance, instead of being stretched
over a dome:

| Layer | Height | Noise cell | At the day's coverage | Opacity |
|-------|--------|------------|-----------------------|---------|
| Low   | 2 km   | 4.5 km     | Heaped clouds over about two fifths of the sky; a full deck in the rain | 100 % |
| High  | 6 km   | 26 km      | A thin veil | 75 % |

**Shape.** `sky_cloud_noise` bakes a tiling noise once: value noise in five
octaves (4 to 64 cells across), each wrapping at the texture's edges, with
mipmaps. Each layer reads it twice per pixel, the second time 3.7× finer and
turned 37°, to fray the edges. The mip level follows the pixel's footprint, so
far clouds don't shimmer. Coverage (`cloudParams.z`) sets the threshold the
noise has to pass: 0.50 by day, up to 0.60 at sunrise and sunset
(`0.50 + sunsetFactor × 0.10`), and 0.92 in the rain. Both layers drift with
`cloudTime × cloudSpeed`. The speed (`0.008 + dayFactor × 0.018`) is at its
fastest whenever the sun is more than about 12° up, and slowest at night.

**Light.** The sun lights the clouds until it has set for them too, which is
after it has set for the ground. From 2 km up it stays in view until it is
1.4° below the horizon, and from 6 km until 2.5°. The moon takes over once the
sun is about 3° down. The light reaching a cloud comes from the transmittance
table at the cloud's own height, so it is white overhead, orange low and red
at the end. The sky view's exposure is folded in, so a cloud stands out from
the sky as much as it would to the eye. How much of that light reaches the low
cloud's underside depends on the cloud's own thickness and on two more reads
toward the light, spaced farther apart the lower the light stands. A low sun
lights the side of a cloud that faces it and leaves the rest grey, and a thick
core, or a rain deck, is darker than the edges. A Henyey–Greenstein forward
peak (g = 0.6) lines the thin edges toward the light with silver.

The shadowed side takes the sky's own light (behind the cloud and overhead)
and a little from the ground below. At night the clouds take a quarter more of
the night's glow than the sky does, so they read grey-blue against it, and
silver near a full moon.

**Haze.** The sky view's alpha holds how much of the low layer shows through
the air in front of it, computed as the transmittance from the eye to the
layer. It is about 1 overhead, under a half on the horizon (150 km away), and 0
below the ground. A cloud is mixed over the sky by its density × that value,
so far clouds fade into the haze in the haze's colour. The high layer takes
the alpha to the power 1.3.

**What's behind them.** The layers composite back to front. Their cover
(`clouds`) dims the sun, the moon and their glows. The catalogue stars take the
same cover, read from the coarse noise at a fixed mip level (a vertex has no
footprint to pick one by).

#### Sun disc and bloom

```metal
float cosG = dot(viewDir, sunDir);
if (sunDir.y > -0.10f && cosG > 0.78f) {                  // only within 39° of the sun
    float disc  = pow(cosG, sky.sunColorAndSize.w);        // tight disc (exponent 300)
    float bloom = pow(cosG, 18.0f) * 0.15f;                // a touch of corona
    float3 discColour = sqrt(sky.sunColorAndSize.rgb);
    colour = mix(colour, discColour, saturate(disc * 1.5f) * discClear);
    colour += sky.sunColorAndSize.rgb * bloom * glowClear;
}
```

The disc exponent is **300**, which gives a stylised but bright disc. The disc
is laid *over* the sky rather than added to it, so an orange or red sun still
shows against the bright glow around it. Its colour is less deep than the
light it gives (`sqrt`), the way the eye sees a sun it can't look at. The
atmosphere's own forward scattering makes the wide glow, and the bloom only
adds a touch. The sun sits behind the clouds: `discClear = 1 − 0.95 × clouds`
hides the disc under a thick cloud, and more of the glow carries through
(`glowClear = 1 − 0.6 × clouds`). The disc takes the sun's own colour
(`SkyEnvironment.sunColor`), not the key light's.

#### Moon

The moon is drawn at its own position (`moonDirectionAndPhase`), at a
stylised angular radius of 2.56° (`SkyRenderer.moonAngularRadius`, 0.0447 rad),
about ten times the real 0.26°. Each pixel of the disc is a point on a sphere
lit from the sun's direction, so the phase and the tilt of its horns follow
from where the two stand: a first-quarter moon is lit on its sunward side in
the afternoon and from below as it sets. Darker seas are fixed to its face.
At night the unlit part takes a faint earthshine (strongest under a thin
crescent) and still hides the stars behind it, and a glow scaled by the moon's
brightness surrounds it. By day the moon shows whenever it is up, drawn at 70%
opacity, so its seas take the blue of the sky. The clouds in front dim it,
like the sun.

#### Bright stars

The 305 catalogue stars are sprites (`sky_star_vertex` / `sky_star_fragment`):
small camera-facing quads at each star's turned direction. They are sized and
brightened by magnitude (Sirius largest) and tinted by colour index, from
blue-white to orange. Everything that dims a star is worked out once per star
in the vertex shader: daylight, the horizon (dimmer and twinkling through the
low air), the moon in front of it or its glare, and the clouds.

---

## Time-of-day reference

Everything keys on where the sun and moon stand, so the clock times shift with
the date and place. The table below is Antananarivo on 21 June (sunrise 06:22,
sunset 17:21, sun elevation from `SkyBodies`), with the moon near first
quarter. Star visibility is `starVisibility` before rain.

| Time | Sun | Sky appearance | Stars | Clouds |
|--------|------|-----------------------------|---------------|-----------------|
| 05:30 | −12° | Night, a faint glow low in the east | 0.59 | Grey-blue, slow drift |
| 06:00 | −6° | Purple dawn over an orange-pink band in the east | 0.27 | Dark against the dawn, thickening slightly |
| 06:30 | +1° | Orange sun on the horizon in a gold glow; pink opposite, over the Earth's blue shadow | 0 | Near peak sunrise coverage, burning orange-red |
| 09:00 | +30° | Deep blue overhead, pale toward the horizon, white-gold sun | 0 | White, grey bases, full speed |
| 12:00 | +48° | Deep blue, the sun 48° up in the north | 0 | White, grey bases |
| 16:00 | +16° | Blue, the sun lower in the west turning gold | 0 | White, grey bases, gold on the sun's side |
| 17:15 | +1° | Sunset: orange disc in a gold band, purple above | 0 | Peak coverage, lit orange from below |
| 17:45 | −6° | Purple twilight, an orange band where the sun went down | 0.29 | Dark against the twilight |
| 18:15 | −12° | Dark blue, a last red line in the west; the moon's faint blue around it | 0.61 | Grey-blue, silver near the moon |
| 19:00 | −22° | Full night | 1 | Grey-blue, slow drift |

---

## Rain

Rain is procedural, with its own schedule. `RainController` runs idle →
fading in (20 s) → active (2–5 min) → fading out (30 s) → idle (1–5 min; the
first wait is 30 s–2 min), and its intensity (0–1) drives everything that
rains. `VRMRenderer.updateRain` scales that intensity by
`RuntimePressurePolicy.rainScale` (×1, ×0.4 on the reduced tier, ×0 on the
minimal tier) before it reaches the sky, the world rain and the wind.

- **On the lens.** `RainSimulator` moves the drops on the CPU (up to 180 drops
  plus 80 small droplets). Each frame `rain_watermap` (compute) writes them
  into a 256×512 water map (refraction normal, depth, alpha), and
  `rain_vertex` / `rain_fragment` draw a fullscreen liquid-glass overlay over
  the finished frame, after the main pass. It plays whenever the environment is
  shown, indoors too.
- **In the world.** 1,500 streaks (`RainWorldRenderer`), whose spawn points
  `RainWorldSimulator` uploads once. `rain_world_vertex` animates each streak
  from `vertex_id` (6 vertices per streak): it falls from 16 m to the ground,
  is wrapped within ±22 m of the camera, and is slanted by a fixed wind. The
  streaks are blended additively and depth-tested without writing depth. They
  are skipped in interiors (`EnvironmentCatalog.isInterior`), where they would
  fall through the ceiling.
- **In the sky.** The coverage rises toward 0.92 (a full low deck), the stars
  dim by up to 95%, `skyOvercast` drains and darkens the sky, and the wind
  grows by up to 1.8×.
- **On the character.** Only the light changes: the sky's light reaches MToon
  through `SkyAmbient.overcast`, drained and darker. The materials themselves
  do not change.

All of the rain lives in `RainShader.metal`.

---

## Flow

```mermaid
flowchart TD
    CLOCK["SkyTimeProvider<br/>instant + time zone<br/>(NL_SKY_* overrides)"] --> PLACE["SkyLocation<br/>zone → lat/long<br/>sky_zones.txt"]
    CLOCK --> EPH["SkyEphemeris<br/>sun · moon · sidereal time"]
    PLACE --> BODIES["SkyBodies<br/>scene directions + compass<br/>moon phase · starRotation"]
    EPH --> BODIES
    BODIES --> ENV["SkyEnvironment.resolve<br/>key · fill · rim · ambient curve<br/>coverage · star visibility"]
    AIR["SkyAtmosphere<br/>sun colour · exposure"] --> ENV

    ENV --> D1["each frame"] --> LIGHTS["applySkyLighting<br/>MToon lights + GI"]
    ENV --> D2["key light"] --> TERR["Terrain · 3D environments<br/>light, shadows, sky hue"]
    ENV --> WIND["SkyWind.velocity<br/>SpringBoneSolver.wind"]

    ENV --> MOVED{"sun or moon<br/>moved 0.1°?"}
    AIR --> D3["exposure"] --> MOVED
    MOVED --> D4["yes"] --> VIEW["sky_view_lut<br/>(transmittance + multiple<br/>scattering built once)"]
    VIEW --> SH["sky_ambient_sh<br/>L1 sum, read back later"]
    SH --> D5["SkyAmbient"] --> ENV

    RAIN["RainController<br/>× rainScale"] --> D6["rain intensity"] --> UNI
    ENV --> UNI["prepareForEncoding<br/>SkyUniformsData"]
    VIEW --> FRAG["sky_fragment<br/>atmosphere · glow · faint stars<br/>clouds · sun · moon"]
    UNI --> FRAG
    FRAG --> STARS{"stars out and<br/>perspective camera?"}
    STARS --> D7["yes"] --> SPR["sky_star_vertex / _fragment<br/>catalogue stars"]

    %% Styles
    classDef core fill:#0f172a,stroke:#7c3aed,color:#a78bfa
    classDef decision fill:#1e293b,stroke:#94a3b8,color:#e2e8f0

    class CLOCK,PLACE,EPH,BODIES,ENV,AIR,LIGHTS,TERR,WIND,VIEW,SH,RAIN,UNI,FRAG,SPR core
    class MOVED,STARS decision

    %% Data nodes (consistent system-wide)
    classDef data fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    class D1,D2,D3,D4,D5,D6,D7 data
```

## Files

| File | Role |
|---|---|
| `NeuraLink/Core/Engine/Sky/SkyTimeProvider.swift` | The device clock and time zone, or a test's, or `NL_SKY_*` |
| `NeuraLink/Core/Engine/Sky/SkyLocation.swift` | Time zone → latitude/longitude, from `sky_zones.txt` |
| `NeuraLink/Core/Engine/Sky/SkyEphemeris.swift` | Sun, moon, sidereal time and precession from the instant (Meeus) |
| `NeuraLink/Core/Engine/Sky/SkyBodies.swift` | Places the sun, moon and stars in the scene (the compass); moon phase and brightness |
| `NeuraLink/Core/Engine/Sky/SkyColorPalette.swift` | `SkyEnvironment` and `SkyKeyLight`: colours and lights for where the bodies stand |
| `NeuraLink/Core/Engine/Sky/SkyAtmosphere.swift` | The atmosphere's constants (`SkyAtmosphereParams`), the sun's colour through the air, the eye's exposure |
| `NeuraLink/Core/Engine/Sky/SkyAmbient.swift` | The sky's own light at L1 for MToon's GI, the terrain and the environments |
| `NeuraLink/Core/Engine/Sky/SkyWind.swift` | The breeze in the hair and clothes |
| `NeuraLink/Core/Engine/Sky/SkyStarCatalogue.swift` | The bright stars from `sky_bright_stars.txt`, in a GPU buffer |
| `NeuraLink/Core/Engine/Sky/SkyUniforms.swift` | The 256-byte uniform struct (Swift ↔ Metal) |
| `NeuraLink/Core/Engine/Sky/SkyRenderer.swift` | Atmosphere tables, sky-light readback, uniform upload, sky and star draws |
| `NeuraLink/Core/Engine/VRM/Shaders/SkyAtmosphereCommon.metal` | The medium, phase functions, table layouts and the grade, shared |
| `NeuraLink/Core/Engine/VRM/Shaders/SkyAtmosphere.metal` | The three lookup tables, the clouds' noise and the sky's light (compute) |
| `NeuraLink/Core/Engine/VRM/Shaders/SkyShader.metal` | Fullscreen sky (atmosphere, clouds, sun, moon) and the bright-star sprites |
| `NeuraLink/Core/Engine/VRM/Rendering/Renderer/VRMRenderer+Sky.swift` | Sky and rain hooks, `applySkyLighting`, `springBoneWind` |
| `NeuraLink/Core/Engine/Rain/` | `RainController`, lens and world rain renderers and simulators (shaders in `RainShader.metal`) |
| `NeuraLink/Domain/Entities/System/RuntimePressure.swift` | The hot-phone tiers: sky refresh, cloud layers, rain scale |
| `NeuraLink/App/Resources/sky_zones.txt` | IANA time zone → coordinates (tz database `zone.tab`) |
| `NeuraLink/App/Resources/sky_bright_stars.txt` | 305 stars down to magnitude 3.55 (Yale Bright Star Catalogue) |
| `scripts/assets/make_sky_tables.py` | Generates both tables |
| `NeuraLinkTests/Engine/SkySystemTests.swift` | Ephemeris against Meeus and NOAA, compass, key light continuity, exposure, uniform stride |
| `NeuraLinkTests/Engine/SkyTableTests.swift` | The GPU tables: noon blue, sunset red, twilight lit, haze before the clouds |
| `NeuraLinkTests/Engine/SkyAmbientTests.swift` | The sky's light, its shaping for the character, rain's overcast, the `Uniforms` layout |
| `NeuraLinkTests/Engine/SkySnapshots.swift` | Review renders and the gallery above (env-gated) |

---

## Cost

The sky is one fullscreen pass plus the catalogue-star sprites, drawn before
everything else. On a phone's tiled GPU, the pixels that the terrain and the
character cover later are never shaded. Per pixel, the pass does only what
shows:

- The view ray comes from the vertices.
- With no clouds there is no cloud work, because coverage is the same for
  every pixel.
- The sun's terms run only within 39° of it and the moon's within 37°; farther
  out they would add less than 1/255.
- The moon's edges are cosines worked out once on the CPU, and the faint stars
  use an integer hash rather than a sine.
- The atmosphere's tables are rebuilt when a light moves 0.1° (about every
  25 s), not every frame, and the clouds' noise is baked once.

Measured over the whole screen at the iPhone 11's resolution (828×1792),
natively on an Intel UHD 630, a GPU of about the iPhone 11's class: 1.3 ms
cloudless, 2.4 ms on a cloudy day, 2.7 ms at night. On the phone, the half of
the screen behind the terrain and the character is skipped. Read the device's
own figure from the `SkyBackground` group in a Metal System Trace.

**On a hot phone.** At `RuntimePressurePolicy`'s reduced tier (serious heat or
Low Power Mode) and minimal tier (critical heat), the sky view is lit again
every 0.2° instead of every 0.1°, so half as often. Only the low cloud layer is
drawn; the high veil goes. A cloudy day then measures 1.9 ms.

---

## Checking the sky

- **Run the clock elsewhere.** Set `NL_SKY_DATE` (`yyyy-MM-dd`) and/or
  `NL_SKY_TIME` (`HH:mm`) in the scheme's environment to start the sky's clock
  at that moment, and `NL_SKY_SPEED` to run it faster (`60` = a minute a
  second). `NL_SKY_ZONE` (an IANA name such as `Europe/Paris`) moves the sky to
  that zone's city and reads the date and time there. The log shows
  `[Sky] clock overridden: …` and, at launch, `[Sky] drawn for <zone>: <lat>°,
  <long>°`. Use these to watch a dawn, a moonrise or the other hemisphere on a
  device without waiting.
- **Snapshots.** `SkySnapshots` (gated by `NL_SKY_SNAPSHOT_DIR`; limit the days
  with `NL_SKY_SNAPSHOT_DAYS`) renders the default character on the open
  terrain at fixed dates and times in Antananarivo: 21 June (a first-quarter
  evening), 26 October (a full moon) and 21 December (a waxing gibbous). It
  takes several shots:
  - the figure;
  - the sky toward the light and the sky away from it;
  - a high sun looked at straight;
  - the moon close up whenever it is up;
  - at night, the sky toward the celestial pole (the Southern Cross and the
    Pointers).

  It writes the sun, moon and key-light angles, the moon's lit fraction and the
  key intensity to `report.txt`. The report also records the GPU time of the sky
  pass alone at 1170×2532, at a cloudy noon and on a moonlit night (26
  October). It renders the first day's noon and dusk again in the rain
  (`*_rain.png`). Through the simulator that time is the Mac's and can't be
  trusted; on a device, the pass shows up as `SkyBackground` in a Metal System
  Trace.
- **The gallery.** With `NL_SKY_DOC_DIR` set to the absolute path of
  `docs/Assets/Sky` instead, `SkySnapshots` rewrites the pictures at the top of
  this page:
  - a winter's day toward the sun, and the default character's face through it;
  - the moon through the lunation that starts at the June new moon;
  - the Southern Cross on that moonless night.

  Regenerate them whenever the sky's look changes.
