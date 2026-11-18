# frozen_string_literal: true

# Renders GitLab Optimized config into place from env vars.
require 'yaml'
require 'fileutils'

APP = '/home/git/gitlab'
SRC = '/opt/gitlab-optimized/config'

def subst(text)
  text.gsub(/\$\{([A-Z0-9_]+)(?::-([^}]*))?\}/) do
    ENV.fetch(Regexp.last_match(1)) { Regexp.last_match(2) || abort("render-config: #{Regexp.last_match(1)} is not set") }
  end
end

def deep_merge(base, over)
  base.merge(over) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b }
end

base = YAML.load_file("#{APP}/config/gitlab.yml.example", aliases: true).fetch('production')
overrides = YAML.safe_load(subst(File.read("#{SRC}/gitlab.overrides.yml")))
File.write("#{APP}/config/gitlab.yml", { 'production' => deep_merge(base, overrides) }.to_yaml)

{
  'database.yml' => "#{APP}/config/database.yml",
  'resque.yml' => "#{APP}/config/resque.yml",
  'cable.yml' => "#{APP}/config/cable.yml",
  'gitaly.toml' => '/home/git/gitaly.toml',
  'workhorse.toml' => '/home/git/workhorse.toml'
}.each { |name, dest| File.write(dest, subst(File.read("#{SRC}/#{name}"))) }

FileUtils.cp("#{SRC}/puma.rb", "#{APP}/config/puma.rb")
