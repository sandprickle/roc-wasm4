app "snake"
    packages {
        w4: "../platform/main.roc",
    }
    imports [
        w4.Task.{ Task },
        w4.W4,
        w4.Sprite.{ Sprite },
    ]
    provides [main, Model] to w4

Program : {
    init : Task Model [],
    update : Model -> Task Model [],
}

Model : {
    frameCount : U64,
    snake : Snake,
    fruit : List Point,
    fruitSprite : Sprite,
}

main : Program
main = { init, update }

init : Task Model []
init =
    {} <- setColorPallet |> Task.await

    fruit1 <- getRandomFruit |> Task.await

    fruitSprite = Sprite.new {
        data: [0x00, 0xa0, 0x02, 0x00, 0x0e, 0xf0, 0x36, 0x5c, 0xd6, 0x57, 0xd5, 0x57, 0x35, 0x5c, 0x0f, 0xf0],
        bpp: BPP1,
        width: 8,
        height: 8,
    }

    Task.ok {
        frameCount: 0,
        snake: startingSnake,
        fruit: [fruit1],
        fruitSprite,
    }

update : Model -> Task Model []
update = \prev ->

    # Read gamepad
    { left, right, up, down } <- W4.readGamepad Player1 |> Task.await

    # Update frame
    model = { prev & frameCount: prev.frameCount + 1 }

    # Move snake
    snake =
        prev.snake
        |> \s1 ->
            if (model.frameCount % 15) == 0 then
                moveSnake s1
            else
                s1
        |> \s2 ->
            if left then
                { s2 & direction: Left }
            else if right then
                { s2 & direction: Right }
            else if up then
                { s2 & direction: Up }
            else if down then
                { s2 & direction: Down }
            else
                s2

    # Draw fruit
    {} <- W4.setDrawColors {
            primary: Color1,
            secondary: Color2,
            tertiary: Color3,
            quaternary: Color4,
        }
        |> Task.await
    {} <- Sprite.blit { x: 20, y: 20, flags: [] } model.fruitSprite |> Task.await

    # Draw snake body
    {} <- W4.setRectColors { border: blue, fill: green } |> Task.await
    {} <- drawSnakeBody snake |> Task.await

    # Draw snake head
    {} <- W4.setRectColors { border: blue, fill: blue } |> Task.await
    {} <- drawSnakeHead snake |> Task.await

    # Return model for next frame
    Task.ok { model & snake }

# Set the color pallet
# white = Color1
# orange = Color2
green = Color3
blue = Color4

setColorPallet : Task {} []
setColorPallet =
    W4.setPallet {
        color1: 0xfbf7f3,
        color2: 0xe5b083,
        color3: 0x426e5d,
        color4: 0x20283d,
    }

Point : { x : I32, y : I32 }
Dir : [Up, Down, Left, Right]

Snake : {
    body : List Point,
    head : Point,
    direction : Dir,
}

startingSnake : Snake
startingSnake = {
    body: [{ x: 1, y: 0 }, { x: 0, y: 0 }],
    head: { x: 2, y: 0 },
    direction: Right,
}

drawSnakeBody : Snake -> Task {} []
drawSnakeBody = \snake ->
    List.walk snake.body (Task.ok {}) \task, part ->
        {} <- task |> Task.await

        W4.rect (part.x * 8) (part.y * 8) 8 8

drawSnakeHead : Snake -> Task {} []
drawSnakeHead = \snake ->
    W4.rect (snake.head.x * 8) (snake.head.y * 8) 8 8

moveSnake : Snake -> Snake
moveSnake = \prev ->

    head =
        when prev.direction is
            Up -> { x: prev.head.x, y: (prev.head.y + 20 - 1) % 20 }
            Down -> { x: prev.head.x, y: (prev.head.y + 1) % 20 }
            Left -> { x: (prev.head.x + 20 - 1) % 20, y: prev.head.y }
            Right -> { x: (prev.head.x + 1) % 20, y: prev.head.y }

    walkBody : Point, List Point, List Point -> List Point
    walkBody = \last, remaining, newBody ->
        when remaining is
            [] -> newBody
            [curr, .. as rest] ->
                walkBody curr (List.dropFirst remaining 1) (List.append newBody last)

    body = walkBody prev.head prev.body []

    { prev & head, body }

getRandomFruit : Task Point []
getRandomFruit =
    x <- W4.rand |> Task.await
    y <- W4.rand |> Task.await

    Task.ok { x, y }
