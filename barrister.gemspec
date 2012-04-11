Gem::Specification.new do |s|
  s.name = %q{barrister}
  s.version = "0.1.0"
  s.date = %q{2012-04-11}
  s.authors = [ "James Cooper" ]
  s.homepage = "https://github.com/coopernurse/barrister-ruby"
  s.summary = %q{Ruby bindings for Barrister RPC}
  s.license = "MIT"
  s.add_dependency('json', '>= 1.5.0')
  s.files = [
    "lib/barrister.rb"
  ]
  s.require_paths = ["lib"]
  s.description = <<-EOF
Barrister RPC makes it easy to expose type safe services. This module
provides Ruby bindings for Barrister.
EOF
end
