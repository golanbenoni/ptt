#!/usr/bin/env bash
set -euo pipefail

label="${1:?latency label is required}"
samples="${2-}"
expected="${3:?expected sample count is required}"
maximum_ms="${4:?maximum latency is required}"

ruby -e '
  label, raw, expected_raw, maximum_raw = ARGV
  abort "#{label}: expected count must be a positive integer" unless expected_raw.match?(/\A[1-9][0-9]*\z/)
  abort "#{label}: maximum must be a positive integer" unless maximum_raw.match?(/\A[1-9][0-9]*\z/)
  values = raw.split(",", -1)
  abort "#{label}: missing latency samples" if raw.empty?
  abort "#{label}: malformed latency samples: #{raw.inspect}" unless values.all? { |value| value.match?(/\A[0-9]+\z/) }
  values.map!(&:to_i)
  expected = expected_raw.to_i
  maximum = maximum_raw.to_i
  abort "#{label}: expected #{expected} samples, received #{values.length}" unless values.length == expected
  sorted = values.sort
  rank = [(0.95 * sorted.length).ceil - 1, 0].max
  p95 = sorted.fetch(rank)
  abort "#{label}: p95 #{p95}ms exceeds #{maximum}ms (samples=#{values.join(",")})" if p95 > maximum
  puts "#{label}: p95=#{p95}ms budget=#{maximum}ms samples=#{values.join(",")}"
' "$label" "$samples" "$expected" "$maximum_ms"
