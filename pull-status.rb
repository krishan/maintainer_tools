#!/usr/bin/env ruby

require "rubygems"

require "restclient"

gem "hub", "= 1.10.1"
require "hub"

require_relative "pull_request"

include Hub::Context
include Hub::GitHubAPI::HttpMethods

def sh(cmd)
  output = %x{#{cmd} 2>&1}
  raise "'command #{cmd}' failed with #{output}" unless $? == 0

  output
end

module WithCruises

  def cruises
    @cruises ||=
      begin
        comment_bodies = comments.map { |comment| comment.body }
        cruise_urls = (comment_bodies + [data["body"]]).
          map { |text| text.scan(/(http:\/\/cruise\S+)/) }.
          flatten

        cruise_urls.
          map do |url|
            output =
              begin
                RestClient.get(url)
              rescue RestClient::ResourceNotFound
              end

            {:url => url, :output => output}
          end.
          reject do |cruise|
            cruise[:output] == nil
          end
      end
  end

  def successful_cruises
    (cruises_by_success["success"] || []).map { |cruise| cruise[:url] }
  end

  def failing_cruises
    (cruises_by_success["failure"] || []).map { |cruise| cruise[:url] }
  end

  def cruises_by_success
    current_cruises = cruises.select { |cruise| cruise[:output].include?(current_sha) }

    current_cruises.group_by do |cruise|
      output = cruise[:output]
      if output.include?("failure")
        "failure"
      elsif output.include?("in_progress")
        "in_progress"
      elsif output.include?("success")
        "success"
      else
        raise "cannot parse #{cruise[:url]}"
      end
    end
  end
end

PullRequest.__send__(:include, WithCruises)

def output_choices(pull_request)
  puts "possible choices:"
  puts "OK (#{pull_request.current_sha})"
  puts "FEEDBACK (#{pull_request.current_sha})"
  puts
end

def open_url(url)
  sh "open #{url} || firefox #{url} || firefox-bin #{url}"
end

def open_compare(project, pull_request, from, to)
  open_url project.web_url("/compare/#{from}...#{to}")
end

def sha_equal(a, b)
  a[0..6] == b[0..6]
end

def find_merge_base(master_rev, branch_rev)
  sh("git merge-base #{master_rev} #{branch_rev}").strip
end

def find_merge_base_with_pull(pull_request)
  current_branch_name = sh "git rev-parse --abbrev-ref HEAD".strip
  retried = false

  begin
    find_merge_base(pull_request.master_branch_current_sha, pull_request.current_sha)
  rescue
    raise if retried
    sh "git co #{pull_request.master_branch_name}"
    sh "git pull"
    retried = true
    retry
  ensure
    sh "git checkout #{current_branch_name}"
  end
end


project = local_repo.main_project

pull_url = ARGV[0]
unless pull_url =~ /\/pull\/(\d+)/
  puts "usage: pull-status.rb <github pull url>"
  exit
end
pull_id = $1

api = Hub::Commands.__send__(:api_client)

pull_request = PullRequest.new(api.pullrequest_info(project, pull_id))

puts "pull request sha: #{pull_request.current_sha}"
puts

if !pull_request.current_review
  puts "never reviewed."
  if lmc = pull_request.maintainer_comments.last
    puts "last maintainer comment:"
    puts lmc.body
  end
  output_choices(pull_request)
elsif !sha_equal(pull_request.current_review.sha, pull_request.current_sha)
  puts "unreviewed commits present. opening in brower."
  open_compare(project, pull_request, pull_request.current_review.sha, pull_request.current_sha)

  puts
  puts "last approval from maintainer was:"
  puts pull_request.current_review
  puts

  output_choices(pull_request)
else
  puts "everything reviewed, approval: #{pull_request.current_review}"
end


if !pull_request.successful_cruises.empty?
  puts "successful cruises: #{pull_request.successful_cruises.join(", ")}"
elsif !pull_request.failing_cruises.empty?
  puts "only failing cruises."
  open_url pull_request.failing_cruises.first
else
  puts "no current cruises."
end
puts

# base_sha1 = sh("git ls-remote #{pull_request.base_repo["ssh_url"]} #{pull_request.master_branch_name}").split(" ").first

sh "git co #{pull_request.master_branch_name}"
sh "hub co #{pull_url}"

merge_base = find_merge_base_with_pull(pull_request)

if merge_base == pull_request.master_branch_current_sha
  puts "pull request is fast-forward-able."
else
  puts "pull request must be merged, merge base is #{merge_base}."
  open_compare(project, pull_request, merge_base, pull_request.master_branch_name)
end
puts

# require "pry"
# binding.pry


