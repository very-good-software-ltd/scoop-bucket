#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates every manifest in bucket/ and the README table from apps.json,
# pulling each tool's latest release version and the sha256 GitHub reports for
# each asset. Run by the "Update manifests" workflow, but also runnable locally.

require "json"

ROOT = File.expand_path("..", __dir__)

# Rust target triple -> Scoop architecture key.
def architecture_of(target)
  abort "Scoop installs Windows builds only, so #{target} cannot be published" unless target.include?("windows")

  return "64bit" if target.start_with?("x86_64")
  return "32bit" if target.start_with?("i686")
  return "arm64" if target.start_with?("aarch64")

  abort "unknown architecture for target #{target}"
end

def api_get(url)
  command = ["curl", "-sSL", "--fail"]
  token = ENV["GITHUB_TOKEN"]
  command += ["-H", "Authorization: Bearer #{token}"] if token && !token.empty?
  command << url
  JSON.parse(IO.popen(command, &:read))
end

def sha256(release, asset_name)
  asset = release.fetch("assets").find { |a| a["name"] == asset_name }
  abort "release has no asset named #{asset_name}" unless asset

  digest = asset["digest"]
  abort "asset #{asset_name} has no sha256 digest" unless digest&.start_with?("sha256:")

  digest.delete_prefix("sha256:")
end

def render_manifest(app, version, assets)
  architecture = assets.to_h do |asset|
    [architecture_of(asset[:target]), { "url" => asset[:url], "hash" => asset[:sha256] }]
  end

  manifest = {
    "version" => version,
    "description" => app["desc"],
    "homepage" => "https://github.com/#{app['repo']}",
    "license" => app["license"],
    "architecture" => architecture,
    "bin" => "#{app['name']}.exe"
  }

  "#{JSON.pretty_generate(manifest)}\n"
end

def update_readme(rows)
  path = File.join(ROOT, "README.md")
  readme = File.read(path)
  markers = /<!-- manifests:start -->.*<!-- manifests:end -->/m
  abort "README.md is missing the manifests markers" unless readme.match?(markers)

  table = ["| Manifest | Version | Description |", "| --- | --- | --- |"]
  rows.each do |row|
    table << "| [#{row[:name]}](https://github.com/#{row[:repo]}) | #{row[:version]} | #{row[:desc]} |"
  end

  # The blank lines around the table are what markdown-style's block-spacing
  # rule expects between a comment and a table.
  block = "<!-- manifests:start -->\n\n#{table.join("\n")}\n\n<!-- manifests:end -->"
  File.write(path, readme.sub(markers, block))
end

apps = JSON.parse(File.read(File.join(ROOT, "apps.json")))
rows = []

apps.each do |app|
  release = api_get("https://api.github.com/repos/#{app['repo']}/releases/latest")
  version = release["tag_name"]
  assets = app["targets"].map do |target|
    asset = "#{app['name']}-#{target}.zip"
    url = "https://github.com/#{app['repo']}/releases/download/#{version}/#{asset}"
    { target: target, url: url, sha256: sha256(release, asset) }
  end

  File.write(File.join(ROOT, "bucket", "#{app['name']}.json"), render_manifest(app, version, assets))
  rows << { name: app["name"], repo: app["repo"], version: version, desc: app["desc"] }
  puts "#{app['name']} -> #{version}"
end

update_readme(rows)

