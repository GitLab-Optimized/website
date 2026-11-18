# frozen_string_literal: true

# Single-mode Puma: one process instead of a master plus N forked workers.
# Saves several hundred MB; a 2-core box gains little from extra workers.
app_root = '/home/git/gitlab'

rackup "#{app_root}/config.ru"
pidfile "#{app_root}/tmp/pids/puma.pid"
state_path "#{app_root}/tmp/pids/puma.state"

threads_count = Integer(ENV.fetch('PUMA_THREADS', 4))
threads threads_count, threads_count
queue_requests false
bind "unix://#{app_root}/tmp/sockets/gitlab.socket"
workers 0

require_relative "#{app_root}/lib/gitlab/cluster/lifecycle_events"
Gitlab::Cluster::LifecycleEvents.set_puma_worker_count(0)

before_restart do
  Gitlab::Cluster::LifecycleEvents.do_before_master_restart
end

tag 'gitlab-puma'
worker_timeout 60

require_relative "#{app_root}/lib/gitlab/puma_logging/json_formatter"
json_formatter = Gitlab::PumaLogging::JSONFormatter.new
log_formatter do |str|
  json_formatter.call(str)
end

require_relative "#{app_root}/lib/gitlab/puma/error_handler"
error_handler = Gitlab::Puma::ErrorHandler.new(true)
lowlevel_error_handler do |ex, env, status_code|
  error_handler.execute(ex, env, status_code)
end
