local app = app
local ply = app.SECTION_PLY
local Drawings = {Main = {}, Sub = {}, Control = {}}

local x

x = app.DrawingInstructions()
x:hline(0, 256, 3)
Drawings.Main.HorizontalLine = x

x = app.DrawingInstructions()
x:hline(0, 256, app.GRID4_LINE1 + 2)
Drawings.Main.TitleLine = x

x = app.DrawingInstructions()
x:hline(0, 128, app.GRID4_LINE1 + 2)
Drawings.Sub.TitleLine = x

x = app.DrawingInstructions()
x:color(app.GRAY11)
x:vline(0.5 * (app.BUTTON1_CENTER + app.BUTTON2_CENTER), 0, 64)
x:vline(0.5 * (app.BUTTON2_CENTER + app.BUTTON3_CENTER), 0, 64)
Drawings.Sub.ThreeColumns = x

x = app.DrawingInstructions()
x:hline(0, 128, app.GRID5_LINE1 + 1)
x:hline(0, 128, app.GRID5_LINE3 - 1)
Drawings.Sub.HelpfulButtons = x

x = app.DrawingInstructions()
x:color(app.WHITE)
x:hline(ply - 7, ply - 3, 60)
x:hline(ply - 7, ply - 3, 56)
x:color(app.GRAY7)
x:hline(ply - 6, ply - 4, 59)
x:hline(ply - 6, ply - 4, 58)
x:hline(ply - 6, ply - 4, 57)
x:vline(ply - 5, 56, 53)
Drawings.Control.Pin = x

-- Centered "+" glyph in a 9x9 area. Used by the hold-mode scenes
-- Performance view for the empty-slot placeholder ply; two
-- crossed single-pixel lines meeting at (4, 4) in the local
-- coordinate space. Bolder than a text "+" at the panel
-- resolution and reusable by anyone else who wants the
-- generic add-slot affordance.
x = app.DrawingInstructions()
x:color(app.WHITE)
x:hline(0, 8, 4)
x:vline(4, 0, 8)
Drawings.Control.Plus = x

return Drawings
