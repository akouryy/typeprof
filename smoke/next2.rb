def foo
  yield
end

foo do
  raise
  "str"
rescue
  next 42
end

__END__
# Classes
class Object
  foo : (&Proc[() -> (Integer | String)]) -> (Integer | String)
end