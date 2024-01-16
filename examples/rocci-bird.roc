app "rocci-bird"
    packages {
        w4: "../platform/main.roc",
    }
    imports [
        w4.Task.{ Task },
        w4.W4.{ Gamepad },
        w4.Sprite.{ Sprite },
    ]
    provides [main, Model] to w4

Program : {
    init : Task Model [],
    update : Model -> Task Model [],
}

Model : [
    TitleScreen TitleScreenState,
    Game GameState,
    GameOver GameOverState,
]

main : Program
main = { init, update }

init : Task Model []
init =
    # Lospec palette: Candy Cloud [2-BIT] Palette
    palette = {
        color1: 0xe6e6c0,
        color2: 0xb494b7,
        color3: 0x42436e,
        color4: 0x26013f,
    }

    {} <- W4.setPalette palette |> Task.await

    plants <- startingPlants |> Task.await
    Task.ok (initTitleScreen 0 plants)

update : Model -> Task Model []
update = \model ->
    when model is
        TitleScreen prev ->
            prev
            |> updateFrameCount
            |> runTitleScreen

        Game prev ->
            prev
            |> updateFrameCount
            |> runGame

        GameOver prev ->
            prev
            |> updateFrameCount
            |> runGameOver

updateFrameCount : { frameCount : U64 }a -> { frameCount : U64 }a
updateFrameCount = \prev ->
    frameCount = Num.addWrap prev.frameCount 1
    { prev & frameCount }

# ===== Title Screen ======================================

TitleScreenState : {
    frameCount : U64,
    plants : List Plant,
    rocciIdleAnim : Animation,
    groundSprite : Sprite,
    plantSpriteSheet : Sprite,
}

initTitleScreen : U64, List Plant -> Model
initTitleScreen = \frameCount, plants ->
    TitleScreen {
        frameCount,
        plants,
        rocciIdleAnim: createRocciIdleAnim frameCount,
        groundSprite: createGroundSprite {},
        plantSpriteSheet: createPlantSpriteSheet {},
    }

runTitleScreen : TitleScreenState -> Task Model []
runTitleScreen = \prev ->
    state = { prev &
        rocciIdleAnim: updateAnimation prev.frameCount prev.rocciIdleAnim,
    }

    {} <- setTextColors |> Task.await
    {} <- W4.text "Rocci Bird!!!" { x: 32, y: 12 } |> Task.await
    {} <- W4.text "Click to start!" { x: 24, y: 72 } |> Task.await

    {} <- drawGround state.groundSprite |> Task.await
    {} <- drawPlants state.plantSpriteSheet state.plants |> Task.await

    shift = idleShift state.frameCount state.rocciIdleAnim

    {} <- drawAnimation state.rocciIdleAnim { x: playerX, y: playerStartY + shift } |> Task.await
    gamepad <- W4.getGamepad Player1 |> Task.await
    mouse <- W4.getMouse |> Task.await

    start = gamepad.button1 || gamepad.up || mouse.left

    if start then
        # Seed the randomness with number of frames since the start of the game.
        # This makes the game feel like it is truely randomly seeded cause players won't always start on the same frame.
        {} <- W4.seedRand state.frameCount |> Task.await
        {} <- W4.tone flapTone |> Task.await

        Task.ok (initGame state)
    else
        Task.ok (TitleScreen state)

# ===== Main Game =========================================

GameState : {
    frameCount : U64,
    score : U8,
    player : {
        y : F32,
        yVel : F32,
    },
    lastPipeGenerated : U64,
    pipes : List Pipe,
    lastFlap : Bool,
    rocciFlapAnim : Animation,
    pipeSprite : Sprite,
    groundSprite : Sprite,
    # If I add these fields and simply wire them into initGame,
    # I will start getting memory errors and out of bounds accesses.
    # plants : List Plant,
    # plantSpriteSheet : Sprite,
}

initGame : TitleScreenState -> Model
initGame =
    \{ frameCount, groundSprite } ->
        Game {
            frameCount,
            score: 0,
            player: {
                y: playerStartY,
                yVel: jumpSpeed,
            },
            lastPipeGenerated: frameCount,
            pipes: [],
            lastFlap: Bool.true,
            rocciFlapAnim: createRocciFlapAnim frameCount,
            pipeSprite: createPipeSprite {},
            groundSprite,
            # plants,
            # plantSpriteSheet,
        }

# Useful to throw in WolframAlpha to help calculate these:
# y =  v^2 /(2a); y = -a/2*t^2 + vt; y = 20; t = 18; a > 0
# y is max jump height in pixels.
# t is frames to reach max jump height (remember 60fps).
gravity = 0.12
jumpSpeed = -2.2

runGame : GameState -> Task Model []
runGame = \prev ->
    gamepad <- W4.getGamepad Player1 |> Task.await
    mouse <- W4.getMouse |> Task.await

    flap = gamepad.button1 || gamepad.up || mouse.left

    { yVel, nextAnim, flapSoundTask } =
        if !prev.lastFlap && flap && flapAllowed prev.frameCount prev.rocciFlapAnim then
            anim = prev.rocciFlapAnim
            {
                yVel: jumpSpeed,
                nextAnim: { anim & index: 0, state: RunOnce },
                flapSoundTask: W4.tone flapTone,
            }
        else
            {
                yVel: prev.player.yVel + gravity,
                nextAnim: updateAnimation prev.frameCount prev.rocciFlapAnim,
                flapSoundTask: Task.ok {},
            }

    {} <- flapSoundTask |> Task.await
    pipe <- maybeGeneratePipe prev.lastPipeGenerated prev.frameCount |> Task.attempt

    lastPipeGenerated =
        if Result.isOk pipe then
            prev.frameCount
        else
            prev.lastPipeGenerated

    pipes =
        prev.pipes
        |> updatePipes
        |> List.appendIfOk pipe

    gainPoint = Num.toU8 (List.countIf prev.pipes \{ x } -> x == playerX - 2)
    y = prev.player.y + yVel
    state = { prev &
        rocciFlapAnim: nextAnim,
        player: { y, yVel },
        score: Num.addWrap prev.score gainPoint,
        lastFlap: flap,
        lastPipeGenerated,
        pipes,
    }

    pointSoundTask =
        if gainPoint > 0 then
            W4.tone pointTone
        else
            Task.ok {}

    {} <- pointSoundTask |> Task.await
    {} <- drawPipes state.pipeSprite state.pipes |> Task.await
    {} <- drawGround state.groundSprite |> Task.await

    yPixel =
        Num.floor state.player.y
        |> Num.min 134

    collided <- playerCollided yPixel state.rocciFlapAnim.index |> Task.await
    {} <- drawAnimation state.rocciFlapAnim { x: playerX, y: yPixel } |> Task.await

    {} <- drawScore state.score |> Task.await

    if !collided && y < 134 then
        Task.ok (Game state)
    else
        {} <- W4.tone deathTone |> Task.await

        Task.ok (initGameOver state)

# ===== Game Over =========================================

GameOverState : {
    frameCount : U64,
    score : U8,
    player : {
        y : F32,
        yVel : F32,
    },
    pipes : List Pipe,
    rocciFallAnim : Animation,
    pipeSprite : Sprite,
    groundSprite : Sprite,
}

initGameOver : GameState -> Model
initGameOver = \{ frameCount, score, pipeSprite, groundSprite, player, pipes } ->
    GameOver {
        frameCount,
        score,
        player,
        pipes,
        rocciFallAnim: createRocciFallAnim frameCount,
        pipeSprite,
        groundSprite,
    }

runGameOver : GameOverState -> Task Model []
runGameOver = \prev ->
    yVel = prev.player.yVel + gravity
    nextAnim = updateAnimation prev.frameCount prev.rocciFallAnim

    y =
        next = prev.player.y + yVel
        if next > 134 then
            134
        else
            next

    state = { prev &
        rocciFallAnim: nextAnim,
        player: { y, yVel },
    }

    {} <- drawPipes state.pipeSprite state.pipes |> Task.await
    {} <- drawGround state.groundSprite |> Task.await

    {} <- W4.setShapeColors { border: Color4, fill: Color1 } |> Task.await
    {} <- W4.rect { x: 16, y: 52, width: 136, height: 32 } |> Task.await
    {} <- setTextColors |> Task.await
    {} <- W4.text "Game Over!" { x: 44, y: 56 } |> Task.await
    {} <- W4.text "Right to restart" { x: 20, y: 72 } |> Task.await
    # If this is commented out, the code will not compile.
    # Error in alias analysis
    # Might as well use it for something, I guess.
    {} <- W4.text "Art by Luke DeVault" { x: 4, y: 151 } |> Task.await

    {} <- W4.setShapeColors { border: Color4, fill: Color1 } |> Task.await
    {} <- W4.rect { x: 66, y: 2, width: 28, height: 12 } |> Task.await
    {} <- drawScore state.score |> Task.await

    yPixel = Num.floor state.player.y
    {} <- drawAnimation state.rocciFallAnim { x: playerX, y: yPixel } |> Task.await

    gamepad <- W4.getGamepad Player1 |> Task.await
    mouse <- W4.getMouse |> Task.await
    if mouse.right || gamepad.button2 then
        plants <- startingPlants |> Task.await
        Task.ok (initTitleScreen state.frameCount plants)
    else
        Task.ok (GameOver state)

# ===== Player ============================================

playerStartY = 40
playerX = 70

playerCollided : I32, U64 -> Task Bool []
playerCollided = \playerY, animIndex ->
    if playerY >= -1 then
        onScreenCollided playerY animIndex
    else
        offScreenCollided

onScreenCollided : I32, U64 -> Task Bool []
onScreenCollided = \playerY, animIndex ->
    # This is written in a kinda silly but simple way.
    # It checks to ensure a few points in the sprite are all background colored.
    # This must be run before drawing the player.
    basePoints = [
        { x: 11, y: 2 },
        { x: 13, y: 3 },
        { x: 3, y: 5 },
        { x: 11, y: 6 },
        { x: 9, y: 8 },
        { x: 5, y: 9 },
        { x: 7, y: 10 },
        { x: 5, y: 12 },
    ]

    collisionPoints =
        if animIndex == 2 then
            basePoints
            |> List.append { x: 2, y: 1 }
            |> List.append { x: 7, y: 1 }
        else if animIndex == 1 then
            basePoints
            |> List.append { x: 2, y: 2 }
        else
            basePoints

    List.walk collisionPoints (Task.ok Bool.false) \collidedTask, { x, y } ->
        collided <- collidedTask |> Task.await
        if collided then
            Task.ok Bool.true
        else
            point = {
                x: Num.toU8 (playerX + x),
                y: Num.toU8 (playerY + y),
            }
            color <- W4.getPixel point |> Task.await
            Task.ok (color != Color1)

offScreenCollided =
    point = {
        x: Num.toU8 (playerX + 13),
        y: Num.toU8 0,
    }
    color <- W4.getPixel point |> Task.await
    Task.ok (color != Color1)

# ===== Pipes =============================================

Pipe : { x : I32, gapStart : I32 }

gapHeight = 40

drawPipes : Sprite, List Pipe -> Task {} []
drawPipes = \sprite, pipes ->
    List.walk pipes (Task.ok {}) \task, pipe ->
        {} <- task |> Task.await
        drawPipe sprite pipe

drawPipe : Sprite, Pipe -> Task {} []
drawPipe = \sprite, { x, gapStart } ->
    {} <- setSpriteColors |> Task.await
    {} <- Sprite.blit sprite { x, y: gapStart - W4.screenHeight, flags: [FlipY] } |> Task.await
    Sprite.blit sprite { x, y: gapStart + gapHeight }

updatePipes : List Pipe -> List Pipe
updatePipes = \pipes ->
    pipes
    |> List.map \pipe -> { pipe & x: pipe.x - 1 }
    |> List.dropIf \pipe -> pipe.x < -20

maybeGeneratePipe : U64, U64 -> Task Pipe [NoPipe]
maybeGeneratePipe = \lastgenerated, framecount ->
    if framecount - lastgenerated > 90 then
        gapStart <- W4.randBetween { start: 0, before: 16 } |> Task.await
        Task.ok { x: W4.screenWidth, gapStart: gapStart * 5 + 10 }
    else
        Task.err NoPipe

# ===== Plants ============================================

Plant : { x : I32, type : U32 }

plantTypes = 30

plantY = W4.screenHeight - 22

randomPlant : I32 -> Task Plant []
randomPlant = \x ->
    type <-
        # This breaks alias analysis somehow.
        # Pretty sure those two types are technically the same...
        # expected type '()', found type 'union { ((),), ((),) }'
        # W4.randBetween { start: 0, before: plantTypes }
        # Biased but a least working solution:
        W4.rand
        |> Task.map Num.toU32
        |> Task.map \t -> t % plantTypes
        |> Task.await

    Task.ok { x, type }

startingPlants : Task (List Plant) []
startingPlants =
    List.range { start: At 0, end: At 14 }
    |> List.walk (Task.ok []) \task, i ->
        plant <- randomPlant (i * 12) |> Task.await
        current <- task |> Task.await

        current
        |> List.append plant
        |> Task.ok

drawPlants : Sprite, List Plant -> Task {} []
drawPlants = \spriteSheet, plants ->
    List.walk plants (Task.ok {}) \task, plant ->
        {} <- task |> Task.await
        drawPlant spriteSheet plant

drawPlant : Sprite, Plant -> Task {} []
drawPlant = \spriteSheet, { x, type } ->
    sprite = Sprite.subOrCrash spriteSheet { srcX: type * 12, srcY: 0, width: 12, height: 12 }

    {} <- setSpriteColors |> Task.await
    Sprite.blit sprite { x, y: plantY }

# ===== Sounds ============================================

flapTone = {
    startFreq: 700,
    endFreq: 870,
    channel: Pulse1 Quarter,
    attackTime: 10,
    sustainTime: 0,
    decayTime: 3,
    releaseTime: 5,
    volume: 10,
    peakVolume: 20,
}

pointTone = {
    startFreq: 995,
    endFreq: 1000,
    channel: Pulse2 Half,
    decayTime: 10,
    releaseTime: 10,
    peakVolume: 75,
    volume: 25,
}

deathTone = {
    startFreq: 170,
    endFreq: 40,
    channel: Noise,
    sustainTime: 20,
    releaseTime: 40,
}

# ===== Drawing and Color =================================

drawScore : U8 -> Task {} []
drawScore = \score ->
    {} <- setTextColors |> Task.await
    x =
        if score < 10 then
            76
        else if score < 100 then
            72
        else
            68
    W4.text "$(Num.toStr score)" { x, y: 4 }

drawGround : Sprite -> Task {} []
drawGround = \sprite ->
    {} <- setGroundColors |> Task.await
    Sprite.blit sprite { x: 0, y: W4.screenHeight - 13 }

setTextColors : Task {} []
setTextColors =
    W4.setTextColors { fg: Color4, bg: None }

setSpriteColors : Task {} []
setSpriteColors =
    W4.setDrawColors { primary: None, secondary: Color2, tertiary: Color3, quaternary: Color4 }

setGroundColors : Task {} []
setGroundColors =
    W4.setDrawColors { primary: Color1, secondary: Color2, tertiary: Color3, quaternary: Color4 }

# ===== Animations ========================================

AnimationState : [Completed, RunOnce, Loop]
Animation : {
    lastUpdated : U64,
    index : U64,
    cells : List { frames : U64, sprite : Sprite },
    state : AnimationState,
}

updateAnimation : U64, Animation -> Animation
updateAnimation = \frameCount, anim ->
    framesPerUpdate =
        when List.get anim.cells (Num.toNat anim.index) is
            Ok { frames } ->
                frames

            Err _ ->
                crash "animation cell out of bounds at index: \(anim.index |> Num.toStr)"

    if frameCount - anim.lastUpdated < framesPerUpdate then
        anim
    else
        nextIndex = wrappedInc anim.index (List.len anim.cells |> Num.toU64)
        when anim.state is
            Completed ->
                { anim & lastUpdated: frameCount }

            Loop ->
                { anim & index: nextIndex, lastUpdated: frameCount }

            RunOnce ->
                if nextIndex == 0 then
                    { anim & state: Completed, lastUpdated: frameCount }
                else
                    { anim & index: nextIndex, lastUpdated: frameCount }

drawAnimation : Animation, { x : I32, y : I32, flags ? List [FlipX, FlipY, Rotate] } -> Task {} []
drawAnimation = \anim, { x, y, flags ? [] } ->
    when List.get anim.cells (Num.toNat anim.index) is
        Ok { sprite } ->
            {} <- setSpriteColors |> Task.await
            Sprite.blit sprite { x, y, flags }

        Err _ ->
            crash "animation cell out of bounds at index: \(anim.index |> Num.toStr)"

wrappedInc = \val, count ->
    next = val + 1
    if next == count then
        0
    else
        next

idleShift : U64, Animation -> I32
idleShift = \frameCount, { index, lastUpdated } ->
    if index == 2 then
        0
    else if index == 1 && frameCount - lastUpdated > 3 then
        0
    else
        1

createRocciIdleAnim : U64 -> Animation
createRocciIdleAnim = \frameCount -> {
    lastUpdated: frameCount,
    index: 0,
    state: Loop,
    cells: [
        { frames: 17, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 0, srcY: 0, width: 16, height: 16 } },
        { frames: 6, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 16, srcY: 0, width: 16, height: 16 } },
        { frames: 17, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 32, srcY: 0, width: 16, height: 16 } },
    ],
}

flapAllowed : U64, Animation -> Bool
flapAllowed = \frameCount, { index, lastUpdated } ->
    if index == 2 then
        Bool.true
    else if index == 1 then
        frameCount - lastUpdated > 6
    else
        Bool.false

createRocciFlapAnim : U64 -> Animation
createRocciFlapAnim = \frameCount -> {
    lastUpdated: frameCount,
    index: 2,
    state: Completed,
    cells: [
        { frames: 6, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 16, srcY: 0, width: 16, height: 16 } },
        { frames: 12, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 32, srcY: 0, width: 16, height: 16 } },
        { frames: 1, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 0, srcY: 0, width: 16, height: 16 } },
    ],
}

createRocciFallAnim : U64 -> Animation
createRocciFallAnim = \frameCount -> {
    lastUpdated: frameCount,
    index: 0,
    state: Loop,
    cells: [
        { frames: 10, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 48, srcY: 0, width: 16, height: 16 } },
        { frames: 10, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 64, srcY: 0, width: 16, height: 16 } },
    ],
}

# ===== Sprites ===========================================

rocciSpriteSheet = Sprite.new {
    data: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x15, 0x56, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00, 0x80, 0x40, 0x05, 0x56, 0x81, 0x80, 0x14, 0x00, 0x01, 0x80, 0x00, 0x00, 0x01, 0x80, 0x00, 0x02, 0x85, 0x00, 0x00, 0x02, 0x81, 0x40, 0x01, 0x56, 0xa5, 0xa0, 0x15, 0x00, 0x05, 0xa0, 0x00, 0x00, 0x05, 0xa0, 0x00, 0x0a, 0x95, 0x00, 0x00, 0x0a, 0x85, 0x40, 0x00, 0x56, 0xa9, 0x00, 0x15, 0x56, 0xa5, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x06, 0x55, 0x00, 0x00, 0x06, 0x55, 0x40, 0x00, 0x06, 0xaa, 0x00, 0x15, 0x5a, 0xaa, 0x00, 0x15, 0x56, 0xaa, 0x00, 0x00, 0x16, 0x95, 0x00, 0x00, 0x06, 0x95, 0x00, 0x00, 0x09, 0x55, 0x00, 0x15, 0x6a, 0xa9, 0x00, 0x05, 0x56, 0xa9, 0x00, 0x00, 0x16, 0x94, 0x00, 0x00, 0x16, 0x95, 0x00, 0x00, 0x09, 0x54, 0x00, 0x05, 0x6a, 0x94, 0x00, 0x01, 0x56, 0xa4, 0x00, 0x00, 0x1a, 0x94, 0x00, 0x00, 0x16, 0x94, 0x00, 0x00, 0x09, 0x50, 0x00, 0x00, 0x69, 0x50, 0x00, 0x00, 0x56, 0x90, 0x00, 0x00, 0x1a, 0xa0, 0x00, 0x00, 0x1a, 0xa0, 0x00, 0x00, 0x29, 0x40, 0x00, 0x00, 0x29, 0x40, 0x00, 0x00, 0x26, 0x40, 0x00, 0x00, 0x0a, 0xa0, 0x00, 0x00, 0x0a, 0xa0, 0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x0a, 0x80, 0x00, 0x00, 0x0a, 0x80, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x05, 0x40, 0x00, 0x00, 0x05, 0x40, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0xa5, 0x00, 0x00, 0x00, 0xa5, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    bpp: BPP2,
    width: 80,
    height: 16,
}

createGroundSprite : {} -> Sprite
createGroundSprite = \{} ->
    Sprite.new {
        data: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x65, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x59, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x95, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x45, 0x14, 0x51, 0x85, 0x14, 0x51, 0x49, 0x14, 0x91, 0x45, 0x18, 0x51, 0x54, 0x51, 0x49, 0x24, 0x51, 0x46, 0x14, 0x51, 0x46, 0x15, 0x14, 0x61, 0x45, 0x14, 0x92, 0x45, 0x14, 0x61, 0x46, 0x14, 0x55, 0x14, 0x51, 0x45, 0x14, 0x61, 0x51, 0x45, 0x65, 0x66, 0x56, 0x56, 0x59, 0x56, 0x59, 0x56, 0x55, 0x65, 0x65, 0x56, 0x59, 0x56, 0x59, 0x95, 0x59, 0x59, 0x55, 0x99, 0x59, 0x59, 0x55, 0x95, 0x96, 0x55, 0x99, 0x55, 0x95, 0x95, 0x59, 0x55, 0x96, 0x55, 0x59, 0x59, 0x95, 0x95, 0x96, 0x55, 0x95, 0x95, 0x99, 0x66, 0x65, 0x99, 0x65, 0x96, 0x95, 0x96, 0x59, 0x59, 0x65, 0x99, 0x65, 0xa5, 0x65, 0x96, 0x56, 0x56, 0x65, 0x99, 0x96, 0x59, 0x99, 0x66, 0x5a, 0x56, 0x59, 0x65, 0x96, 0x56, 0x59, 0x66, 0x65, 0x65, 0x66, 0x59, 0x99, 0x59, 0xa6, 0x9a, 0x5a, 0x69, 0x6a, 0x5a, 0x66, 0xa5, 0xa6, 0x9a, 0x9a, 0x6a, 0x6a, 0x5a, 0x65, 0x69, 0xa6, 0xa6, 0x9a, 0x69, 0x69, 0xa5, 0xa6, 0x9a, 0x5a, 0x96, 0x56, 0x9a, 0x6a, 0x6a, 0xa6, 0x9a, 0x9a, 0x96, 0xa9, 0xa6, 0x96, 0x9a, 0x5a, 0x69, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa],
        bpp: BPP2,
        width: 160,
        height: 13,
    }

createPipeSprite : {} -> Sprite
createPipeSprite = \{} ->
    Sprite.new {
        data: [0x0a, 0xaa, 0xaa, 0xab, 0xf0, 0x25, 0x55, 0x55, 0x55, 0x5c, 0x26, 0x96, 0x6a, 0x9a, 0xac, 0x36, 0x96, 0x6a, 0x66, 0xac, 0x36, 0x96, 0x6a, 0x9a, 0xac, 0x0f, 0xff, 0xff, 0xff, 0xf0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0],
        bpp: BPP2,
        width: 20,
        height: 160,
    }

createPlantSpriteSheet : {} -> Sprite
createPlantSpriteSheet = \{} ->
    Sprite.new {
        data: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaa, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x01, 0x40, 0x02, 0xaa, 0x00, 0x02, 0xaa, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xa0, 0x00, 0x00, 0x00, 0x0a, 0x00, 0xa0, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x50, 0x40, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x01, 0x50, 0x00, 0x00, 0x00, 0x10, 0x05, 0x00, 0x08, 0x00, 0x80, 0x08, 0x08, 0x80, 0x00, 0x2a, 0x00, 0x00, 0x08, 0x08, 0x00, 0x00, 0x00, 0x20, 0x00, 0x08, 0x00, 0x20, 0x80, 0x00, 0x00, 0x00, 0x00, 0x20, 0x80, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x40, 0x11, 0x00, 0x15, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x15, 0x05, 0x14, 0x00, 0x28, 0x00, 0x51, 0x45, 0x00, 0x20, 0x01, 0x60, 0x20, 0x81, 0x60, 0x00, 0x80, 0x80, 0x0a, 0xa0, 0x16, 0x00, 0xa8, 0x00, 0x82, 0x15, 0x96, 0x02, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x82, 0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x20, 0x02, 0xa0, 0x00, 0x00, 0x28, 0x00, 0x02, 0x20, 0x00, 0x02, 0x82, 0x00, 0x06, 0x11, 0x11, 0x02, 0xb2, 0xb0, 0x02, 0x80, 0x08, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0xa8, 0x00, 0x02, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x51, 0x40, 0x15, 0x11, 0x15, 0x00, 0x00, 0x00, 0x24, 0x20, 0x80, 0x51, 0x41, 0x50, 0x00, 0x22, 0x00, 0x14, 0x41, 0x44, 0x20, 0x55, 0x60, 0x28, 0x59, 0xa0, 0x02, 0x01, 0x60, 0x20, 0x21, 0x56, 0x02, 0x02, 0x00, 0x83, 0x55, 0xd6, 0x02, 0xaa, 0x00, 0x00, 0x00, 0x00, 0x00, 0x8a, 0x00, 0x00, 0x10, 0x40, 0x02, 0xa8, 0x80, 0x09, 0x5c, 0x00, 0x08, 0x20, 0x08, 0x02, 0x00, 0x00, 0x0a, 0x0a, 0x28, 0x91, 0x44, 0x66, 0x09, 0x6d, 0x5c, 0x0a, 0x08, 0x20, 0x02, 0x0b, 0x00, 0x00, 0x20, 0x00, 0x02, 0x06, 0x00, 0x0a, 0x15, 0xa0, 0x00, 0x00, 0x00, 0x02, 0x15, 0xa0, 0x15, 0x15, 0x08, 0x00, 0x00, 0x00, 0x04, 0x86, 0x60, 0x15, 0x80, 0x48, 0x20, 0x02, 0x08, 0x50, 0x52, 0x94, 0x21, 0x55, 0x60, 0x21, 0x95, 0x60, 0x02, 0x15, 0x60, 0x80, 0x5a, 0xa8, 0x08, 0x05, 0x80, 0x81, 0x69, 0x56, 0x0a, 0xea, 0x00, 0x00, 0x28, 0x00, 0x02, 0xab, 0x80, 0x04, 0x45, 0x10, 0x0a, 0xea, 0x80, 0x03, 0x9a, 0x00, 0x28, 0xa8, 0x20, 0x02, 0x00, 0x00, 0x28, 0x08, 0xa0, 0x45, 0x19, 0x18, 0x03, 0xef, 0xeb, 0x28, 0x28, 0xa8, 0x08, 0x20, 0xc0, 0x00, 0x88, 0x00, 0x02, 0x05, 0x80, 0x26, 0x16, 0x18, 0x02, 0x00, 0x00, 0x02, 0x8a, 0x80, 0x0a, 0x15, 0x28, 0x00, 0x00, 0x08, 0x05, 0x99, 0xb0, 0x26, 0x08, 0xa0, 0x88, 0x02, 0x22, 0xa1, 0x42, 0x05, 0x0a, 0xaa, 0x80, 0x0a, 0xaa, 0x80, 0x00, 0xaa, 0x80, 0x85, 0x5a, 0x70, 0x08, 0x55, 0x80, 0x95, 0x55, 0x56, 0x2b, 0xae, 0x80, 0x00, 0x88, 0x00, 0x0a, 0xee, 0xa0, 0x11, 0x11, 0x40, 0x0b, 0xab, 0xa0, 0x0b, 0xed, 0xe0, 0xba, 0xba, 0xa0, 0x02, 0xa8, 0x00, 0x2a, 0x2a, 0xb8, 0x1a, 0x6a, 0x78, 0x29, 0xbe, 0x68, 0xae, 0xaa, 0xb8, 0x31, 0x81, 0xc0, 0x00, 0x80, 0x00, 0x02, 0x55, 0x80, 0x87, 0x18, 0x18, 0x09, 0x82, 0x80, 0x00, 0xaa, 0x00, 0x28, 0x08, 0x0a, 0x08, 0x20, 0x20, 0x05, 0x65, 0xd0, 0x08, 0x02, 0x00, 0x08, 0xaa, 0x20, 0x28, 0x8a, 0x14, 0x02, 0x17, 0x00, 0x02, 0x17, 0x00, 0x00, 0x27, 0x00, 0x2a, 0xa2, 0x70, 0x02, 0xaa, 0x00, 0x2a, 0xaa, 0xa8, 0x2b, 0xba, 0xa0, 0x00, 0x87, 0x00, 0x2b, 0xae, 0xa8, 0x06, 0x66, 0x80, 0x0b, 0xae, 0xb8, 0x25, 0xb9, 0x5c, 0xba, 0xea, 0xe8, 0x02, 0xe0, 0x00, 0xae, 0xae, 0xea, 0x0b, 0xaa, 0xe0, 0x96, 0x97, 0x96, 0xba, 0xba, 0xea, 0x31, 0x85, 0x70, 0x00, 0xa0, 0x00, 0x02, 0x67, 0x00, 0x87, 0x1c, 0x57, 0x21, 0xc8, 0x70, 0x00, 0x2c, 0x00, 0x08, 0x0a, 0x08, 0x28, 0xa8, 0xa8, 0x01, 0x5f, 0x54, 0x20, 0x00, 0x80, 0x28, 0x2e, 0x28, 0x22, 0x82, 0x0a, 0x02, 0x17, 0x00, 0x02, 0x17, 0x00, 0x00, 0x27, 0x00, 0x09, 0xc2, 0x70, 0x00, 0x9c, 0x00, 0x08, 0x55, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2a, 0xce, 0xac, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xab, 0x5b, 0xea, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x03, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3e, 0xac, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        bpp: BPP2,
        width: 360,
        height: 12,
    }
