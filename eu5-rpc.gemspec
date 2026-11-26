# frozen_string_literal: true
# SPDX-License-Identifier: GPL-3.0-only

require_relative "lib/eu5_rpc"

Gem::Specification.new do |spec|
  spec.name          = "eu5-rpc"
  spec.version       = Eu5Rpc::VERSION
  spec.authors       = ["Buntato"]
  spec.summary       = "Discord Rich Presence for Europa Universalis V"
  spec.description   = "Zero-dependency Ruby Discord Rich Presence tool for Europa Universalis V reading live Paradox logs and save headers (Ironman-safe, no memory reading)."
  spec.homepage      = "https://github.com/buntatoes/eu5-rpc"
  spec.license       = "GPL-3.0-only"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files         = Dir["LICENSE", "README.md", "bin/*", "lib/**/*.rb", "assets/*"]
  spec.bindir        = "bin"
  spec.executables   = ["eu5-rpc"]
  spec.require_paths = ["lib"]
end
