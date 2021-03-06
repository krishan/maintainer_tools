#!/usr/bin/env ruby

require "rubygems"

require "active_support/core_ext/numeric/time"
require "active_support/core_ext/date/calculations"

gem "hub", "= 1.10.1"
require "hub"

require_relative "pull_request"

module RequestStatus

  def needs_review?
    (never_reviewed? && last_status != "FEEDBACK") || last_status == "REVIEW"
  end

  def review_request_date
    if never_reviewed?
      created_at
    else
      Time.parse(last_status_comment.data['created_at'])
    end
  end

  def due_date
    if never_reviewed?
      review_request_date + 2.days
    else
      review_request_date + 1.days
    end
  end

  def overdue?
    due_date < Time.now
  end

  def due_now?
    !overdue? && due_date < Time.now + 1.days
  end

  def not_due?
    !overdue? && !due_now?
  end

  def never_reviewed?
    !current_review
  end

end

PullRequest.__send__(:include, RequestStatus)

api = Hub::Commands.__send__(:api_client)

repos = ["infopark/rails_connector", "infopark/fiona", "infopark/screw_server", "infopark/rake_support"]

raw_requests = []

repos.each do |repo|
  raw_requests += api.get("https://api.github.com/repos/#{repo}/pulls").data
end

requests = raw_requests.map do |raw_data|
  PullRequest.new(raw_data)
end

# filter out requests not against the default branch
requests = requests.select { |request| request.master_branch_name == request.base_branch_name }

# filter out request that have not been updated for a long time
requests = requests.select { |request| request.updated_at >= Time.now - 14.days }

# preload requests in parallel
# lets hope everything is thread-safe :-)
threads = requests.map do |request|
  [
    Thread.new { request.comments },
    Thread.new { request.comparison }
  ]
end
threads.flatten.each(&:join)

requests_to_review = requests.select(&:needs_review?).sort_by(&:due_date)

requests_to_review.each do |request|
  puts "# #{request.data["user"]["login"]}/#{request.data["base"]["repo"]["name"]}: #{request.title}"
  puts request.data["html_url"]
  puts "Changed Lines: #{request.number_of_changed_lines}"
  puts "NOT DUE" if request.not_due?
  puts "RE-REVIEW" unless request.never_reviewed?
  puts "PRE-OK" if request.pre_ok?
  puts
end

if false
  require "pry"
  binding.pry
end

