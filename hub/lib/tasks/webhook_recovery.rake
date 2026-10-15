namespace :replica do
  namespace :github do
    desc "Report retained webhook recovery status without contacting GitHub"
    task webhook_recovery: :environment do
      configuration = GithubAppConfiguration.current
      checkpoint = WebhookRecoveryCheckpoint.find_by(github_app_configuration_id: configuration&.id)
      puts "App: #{configuration ? "configured" : "not configured"}"
      puts "Recovery last complete: #{checkpoint&.last_completed_at&.iso8601 || "never"}"
      puts "Recovery coverage through: #{checkpoint&.last_completed_scan_started_at&.iso8601 || "never"}"
      puts "Recovery failure: #{checkpoint&.failure_code || "none"}"
      puts "Consecutive scan failures: #{checkpoint&.failures || 0}"
      if checkpoint&.gap_started_at
        puts "Unresolved recovery gap: #{checkpoint.gap_started_at.iso8601} to #{checkpoint.gap_ended_at.iso8601}"
      end
      WebhookRedelivery.group(:state, :failure_code).count.sort_by { |(state, code), _| [ state, code.to_s ] }
        .each do |(state, code), count|
          puts "Retained deliveries: #{state} / #{code || "none"}: #{count}"
        end
    end
  end
end
