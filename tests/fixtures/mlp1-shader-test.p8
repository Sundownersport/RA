pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
function _draw()
 cls(1)
 for y=0,127,16 do
  for x=0,127,16 do
   rectfill(x,y,x+15,y+15,(x/16+y/16)%16)
  end
 end
 rectfill(8,48,119,79,0)
 print("leaf shader test",31,57,7)
 print("1px color grid",36,66,11)
end
