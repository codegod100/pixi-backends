import cligen
proc greet(name = "world", times = 1) =
  ## Greet someone
  for _ in 1..times: echo "Hello, ", name, "!"
when isMainModule: dispatch greet
