pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
offset=0

function _update()
 offset=(offset+1)%8
end

function _draw()
 cls(0)

 -- full pico-8 color ramp
 for i=0,15 do
  rectfill(i*8,0,i*8+7,15,i)
 end

 -- dark-to-bright neutral steps
 local grays={0,1,5,13,6,7}
 for i=1,6 do
  rectfill((i-1)*21,18,i*21-1,31,grays[i])
 end

 -- single-pixel checkerboard
 for y=34,61 do
  for x=0,43 do
   pset(x,y,(x+y)%2==0 and 7 or 0)
  end
 end

 -- moving one-pixel grid
 rectfill(47,34,127,61,1)
 for x=47+offset,127,8 do
  line(x,34,x,61,12)
 end
 for y=34+offset,61,8 do
  line(47,y,127,y,12)
 end

 -- hard edges, thin lines, and readable text
 rectfill(0,65,127,127,1)
 rectfill(5,70,122,122,0)
 line(10,76,117,76,7)
 line(10,79,117,79,6)
 rect(9,84,118,117,5)
 print("leaf shader visual",26,91,7)
 print("1px grid + text",31,101,11)
 print("dark / bright",38,111,10)
end
