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

    frameCount = 0
    Task.ok
        (
            TitleScreen {
                frameCount,
                pipe : {x: 140, gapStart: 50 },
                rocciIdleAnim: createRocciIdleAnim frameCount,
                groundSprite: createGroundSprite {},
                pipeSprite: createPipeSprite {},
            }
        )

update : Model -> Task Model []
update = \model ->
    when model is
        TitleScreen state ->
            state
            |> updateFrameCount
            |> runTitleScreen

        Game state ->
            state
            |> updateFrameCount
            |> runGame

        GameOver state ->
            state
            |> updateFrameCount
            |> runGameOver

updateFrameCount : { frameCount : U64 }a -> { frameCount : U64 }a
updateFrameCount = \prev ->
    { prev & frameCount: Num.addWrap prev.frameCount 1 }

# ===== Title Screen ======================================

TitleScreenState : {
    frameCount : U64,
    pipe : Pipe,
    rocciIdleAnim : Animation,
    groundSprite : Sprite,
    pipeSprite : Sprite,
}

runTitleScreen : TitleScreenState -> Task Model []
runTitleScreen = \prev ->
    state = { prev &
        rocciIdleAnim: updateAnimation prev.frameCount prev.rocciIdleAnim,
    }

    {} <- setTextColors |> Task.await
    {} <- W4.text "Rocci Bird!!!" { x: 32, y: 12 } |> Task.await
    {} <- W4.text "Press X to start!" { x: 16, y: 72 } |> Task.await

    {} <- drawPipe state.pipeSprite state.pipe |> Task.await
    {} <- drawGround state.groundSprite |> Task.await

    shift =
        (state.frameCount // halfRocciIdleAnimTime + 1) % 2 |> Num.toI32

    {} <- drawAnimation state.rocciIdleAnim { x: 70, y: 40 + shift } |> Task.await
    gamepad <- W4.getGamepad Player1 |> Task.await
    mouse <- W4.getMouse |> Task.await

    start = gamepad.button1 || gamepad.up || mouse.left

    if start then
        # Seed the randomness with number of frames since the start of the game.
        # This makes the game feel like it is truely randomly seeded cause players won't always start on the same frame.
        {} <- W4.seedRand state.frameCount |> Task.await

        Task.ok (initGame state)
    else
        Task.ok (TitleScreen state)

# ===== Main Game =========================================

GameState : {
    frameCount : U64,
    rocciFlapAnim : Animation,
    pipeSprite : Sprite,
    groundSprite : Sprite,
    player : {
        y : F32,
        yVel : F32,
    },
    pipes : List Pipe,
}

initGame : TitleScreenState -> Model
initGame = \{ frameCount, pipeSprite, groundSprite, pipe } ->
    Game {
        frameCount,
        rocciFlapAnim: createRocciFlapAnim frameCount,
        pipeSprite,
        groundSprite,
        player: {
            y: 60,
            yVel: 0.5,
        },
        pipes : [pipe]
    }

# With out explicit typing `f32`, roc fails to compile this.
# TODO: finetune gravity and jump speed
gravity = 0.15f32
jumpSpeed = -3.0f32

runGame : GameState -> Task Model []
runGame = \prev ->
    gamepad <- W4.getGamepad Player1 |> Task.await
    mouse <- W4.getMouse |> Task.await

    # TODO: add timeout for press.
    flap = gamepad.button1 || gamepad.up || mouse.left

    (yVel, nextAnim) =
        if flap then
            anim = prev.rocciFlapAnim
            (
                jumpSpeed,
                { anim & index: 0, state: RunOnce },
            )
        else
            (
                prev.player.yVel + gravity,
                updateAnimation prev.frameCount prev.rocciFlapAnim,
            )

    y = prev.player.y + yVel
    state = { prev &
        rocciFlapAnim: nextAnim,
        player: { y, yVel },
        pipes: updatePipes prev.pipes,
    }

    {} <- drawPipes state.pipeSprite state.pipes |> Task.await
    {} <- drawGround state.groundSprite |> Task.await

    yPixel =
        Num.floor state.player.y
        |> Num.min 134
    {} <- drawAnimation state.rocciFlapAnim { x: 20, y: yPixel } |> Task.await

    if y < 134 then
        Task.ok (Game state)
    else
        Task.ok (initGameOver state)

# ===== Game Over =========================================

GameOverState : {
    frameCount : U64,
    rocciFallAnim : Animation,
    pipeSprite : Sprite,
    groundSprite : Sprite,
    player : {
        y : F32,
        yVel : F32,
    },
    pipes : List Pipe,
}

initGameOver : GameState -> Model
initGameOver = \{ frameCount, pipeSprite, groundSprite, player, pipes } ->
    GameOver {
        frameCount,
        rocciFallAnim: createRocciFallAnim frameCount,
        pipeSprite,
        groundSprite,
        player,
        pipes,
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

    {} <- setTextColors |> Task.await
    {} <- W4.text "Game Over!" { x: 44, y: 12 } |> Task.await

    {} <- drawPipes state.pipeSprite state.pipes |> Task.await
    {} <- drawGround state.groundSprite |> Task.await

    yPixel = Num.floor state.player.y
    {} <- drawAnimation state.rocciFallAnim { x: 20, y: yPixel } |> Task.await

    Task.ok (GameOver state)

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

# ===== Misc Drawing and Color ============================

drawGround : Sprite -> Task {} []
drawGround = \sprite ->
    {} <- setGroundColors |> Task.await
    Sprite.blit sprite { x: 0, y: W4.screenHeight - 12 }

setTextColors : Task {} []
setTextColors =
    W4.setTextColors { fg: Color4, bg: None }

setSpriteColors : Task {} []
setSpriteColors =
    W4.setDrawColors { primary: None, secondary: Color2, tertiary: Color3, quaternary: Color4 }

setGroundColors : Task {} []
setGroundColors =
    W4.setDrawColors { primary: Color1, secondary: Color2, tertiary: Color3, quaternary: Color4 }

halfRocciIdleAnimTime = 20

rocciSpriteSheet = Sprite.new {
    data: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x15, 0x56, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00, 0x80, 0x40, 0x05, 0x56, 0x81, 0x80, 0x14, 0x00, 0x01, 0x80, 0x00, 0x00, 0x01, 0x80, 0x00, 0x02, 0x85, 0x00, 0x00, 0x02, 0x81, 0x40, 0x01, 0x56, 0xa5, 0xa0, 0x15, 0x00, 0x05, 0xa0, 0x00, 0x00, 0x05, 0xa0, 0x00, 0x0a, 0x95, 0x00, 0x00, 0x0a, 0x85, 0x40, 0x00, 0x56, 0xa9, 0x00, 0x15, 0x56, 0xa5, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x06, 0x55, 0x00, 0x00, 0x06, 0x55, 0x40, 0x00, 0x06, 0xaa, 0x00, 0x15, 0x5a, 0xaa, 0x00, 0x15, 0x56, 0xaa, 0x00, 0x00, 0x16, 0x95, 0x00, 0x00, 0x06, 0x95, 0x00, 0x00, 0x09, 0x55, 0x00, 0x15, 0x6a, 0xa9, 0x00, 0x05, 0x56, 0xa9, 0x00, 0x00, 0x16, 0x94, 0x00, 0x00, 0x16, 0x95, 0x00, 0x00, 0x09, 0x54, 0x00, 0x05, 0x6a, 0x94, 0x00, 0x01, 0x56, 0xa4, 0x00, 0x00, 0x1a, 0x94, 0x00, 0x00, 0x16, 0x94, 0x00, 0x00, 0x09, 0x50, 0x00, 0x00, 0x69, 0x50, 0x00, 0x00, 0x56, 0x90, 0x00, 0x00, 0x1a, 0xa0, 0x00, 0x00, 0x1a, 0xa0, 0x00, 0x00, 0x29, 0x40, 0x00, 0x00, 0x29, 0x40, 0x00, 0x00, 0x26, 0x40, 0x00, 0x00, 0x0a, 0xa0, 0x00, 0x00, 0x0a, 0xa0, 0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x29, 0x00, 0x00, 0x00, 0x0a, 0x80, 0x00, 0x00, 0x0a, 0x80, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x05, 0x40, 0x00, 0x00, 0x05, 0x40, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0xa5, 0x00, 0x00, 0x00, 0xa5, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    bpp: BPP2,
    width: 80,
    height: 16,
}

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

createRocciFlapAnim : U64 -> Animation
createRocciFlapAnim = \frameCount -> {
    lastUpdated: frameCount,
    index: 2,
    state: Completed,
    cells: [
        # TODO: finetune timing and add eventual fall animation.
        { frames: 6, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 16, srcY: 0, width: 16, height: 16 } },
        { frames: 12, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 32, srcY: 0, width: 16, height: 16 } },
        { frames: 12, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 0, srcY: 0, width: 16, height: 16 } },
    ],
}

createRocciFallAnim : U64 -> Animation
createRocciFallAnim = \frameCount -> {
    lastUpdated: frameCount,
    index: 0,
    state: Loop,
    cells: [
        # TODO: finetune timing.
        { frames: 10, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 48, srcY: 0, width: 16, height: 16 } },
        { frames: 10, sprite: Sprite.subOrCrash rocciSpriteSheet { srcX: 64, srcY: 0, width: 16, height: 16 } },
    ],
}

createGroundSprite : {} -> Sprite
createGroundSprite = \{} ->
    Sprite.new {
        data: [0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x65, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x59, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x95, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x45, 0x14, 0x51, 0x85, 0x14, 0x51, 0x49, 0x14, 0x91, 0x45, 0x18, 0x51, 0x54, 0x51, 0x49, 0x24, 0x51, 0x46, 0x14, 0x51, 0x46, 0x15, 0x14, 0x61, 0x45, 0x14, 0x92, 0x45, 0x14, 0x61, 0x46, 0x14, 0x55, 0x14, 0x51, 0x45, 0x14, 0x61, 0x51, 0x45, 0x65, 0x66, 0x56, 0x56, 0x59, 0x56, 0x59, 0x56, 0x55, 0x65, 0x65, 0x56, 0x59, 0x56, 0x59, 0x95, 0x59, 0x59, 0x55, 0x99, 0x59, 0x59, 0x55, 0x95, 0x96, 0x55, 0x99, 0x55, 0x95, 0x95, 0x59, 0x55, 0x96, 0x55, 0x59, 0x59, 0x95, 0x95, 0x96, 0x55, 0x95, 0x95, 0x99, 0x66, 0x65, 0x99, 0x65, 0x96, 0x95, 0x96, 0x59, 0x59, 0x65, 0x99, 0x65, 0xa5, 0x65, 0x96, 0x56, 0x56, 0x65, 0x99, 0x96, 0x59, 0x99, 0x66, 0x5a, 0x56, 0x59, 0x65, 0x96, 0x56, 0x59, 0x66, 0x65, 0x65, 0x66, 0x59, 0x99, 0x59, 0xa6, 0x9a, 0x5a, 0x69, 0x6a, 0x5a, 0x66, 0xa5, 0xa6, 0x9a, 0x9a, 0x6a, 0x6a, 0x5a, 0x65, 0x69, 0xa6, 0xa6, 0x9a, 0x69, 0x69, 0xa5, 0xa6, 0x9a, 0x5a, 0x96, 0x56, 0x9a, 0x6a, 0x6a, 0xa6, 0x9a, 0x9a, 0x96, 0xa9, 0xa6, 0x96, 0x9a, 0x5a, 0x69, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa],
        bpp: BPP2,
        width: 160,
        height: 12,
    }

createPipeSprite : {} -> Sprite
createPipeSprite = \{} ->
    Sprite.new {
        data: [0x0a, 0xaa, 0xaa, 0xab, 0xf0, 0x25, 0x55, 0x55, 0x55, 0x5c, 0x26, 0x96, 0x6a, 0x9a, 0xac, 0x36, 0x96, 0x6a, 0x66, 0xac, 0x36, 0x96, 0x6a, 0x9a, 0xac, 0x0f, 0xff, 0xff, 0xff, 0xf0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0, 0x03, 0x65, 0x9a, 0x66, 0xc0, 0x03, 0x65, 0x9a, 0x9a, 0xc0],
        bpp: BPP2,
        width: 20,
        height: 160,
    }
