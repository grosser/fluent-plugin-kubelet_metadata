# frozen_string_literal: true
name = "fluent-plugin-kubelet_metadata"

Gem::Specification.new name, "0.1.0" do |s|
  s.summary = "Add metadata to docker logs by asking kubelet api"
  s.authors = ["Michael Grosser"]
  s.email = "michael@grosser.it"
  s.homepage = "https://github.com/grosser/#{name}"
  s.files = `git ls-files lib/ bin/ MIT-LICENSE`.split("\n")
  s.license = "MIT"
  s.required_ruby_version = ">= 2.5.0"
  s.add_runtime_dependency 'fluentd', ['>= 1', '< 2']
end
