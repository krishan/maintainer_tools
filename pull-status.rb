#!/usr/bin/env ruby

require "rubygems"

require "pp"
require "restclient"

gem "hub", "= 1.10.1"
require "hub"

include Hub::Context
include Hub::GitHubAPI::HttpMethods

def sh(cmd)
  output = %x{#{cmd} 2>&1}
  raise "'command #{cmd}' failed with #{output}" unless $? == 0

  output
end

SHA_REGEXP = /\(\s*([0-9a-f]{7,40})\s*\)/

class PullRequest < Struct.new(:project, :pull_id)
  def info
    @info ||= api.pullrequest_info(project, pull_id)
  end

  def base_repo
    info["base"]["repo"]
  end

  def master_branch_current_sha
    master_branch_info["commit"]["sha"]
  end

  def master_branch_info
    @master_branch_info ||= api.get(base_repo["url"]+"/branches/#{master_branch_name}").data
  end

  def master_branch_name
    base_repo["master_branch"]
  end

  def current_sha
    info["head"]["sha"][0..6]
  end

  def comments
    @comments ||= api.get(info["_links"]["comments"]["href"]).data
  end

  def api
    Hub::Commands.__send__(:api_client)
  end

  def last_reviewed_sha
    if last_feedback
      last_feedback.match(SHA_REGEXP)[1]
    end
  end

  def maintainers
    %w(
      kostia
      krishan
    )
  end

  def maintainer_comments
    comments.select { |comment| maintainers.include? comment['user']['login'] }
  end

  def last_feedback
    feedback_comments = maintainer_comments.select do |comment|
      find_maintainer_comment(comment["body"])
    end

    unless feedback_comments.empty?
      feedback_comments.last['body']
    end
  end

  def cruises
    @cruises ||=
      begin
        comment_bodies = comments.map { |comment| comment["body"] }
        cruise_urls = (comment_bodies + [info["body"]]).
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

def output_choices(pull_request)
  puts "possible choices:"
  puts "OK (#{pull_request.current_sha})"
  puts "FEEDBACK (#{pull_request.current_sha})"
  puts
end

def find_maintainer_comment(comment_body)
  if comment_body =~ /(FEEDBACK|OK) / && comment_body =~ SHA_REGEXP
    $1
  end
end

def open_compare(pull_request, from, to)
  compare_url = pull_request.project.web_url("/compare/#{from}...#{to}")
  sh "open #{compare_url}"
end

def sha_equal(a, b)
  a[0..6] == b[0..6]
end

project = local_repo.main_project

pull_url = ARGV[0]
unless pull_url =~ /\/pull\/(\d+)/
  puts "usage: pull-status.rb <github pull url>"
  exit
end
pull_id = $1

pull_request = PullRequest.new(project, pull_id)

puts "pull request sha: #{pull_request.current_sha}"
puts

if !pull_request.last_reviewed_sha
  puts "never reviewed."
  if lmc = pull_request.maintainer_comments.last
    puts "last maintainer comment:"
    puts lmc["body"]
  end
  output_choices(pull_request)
elsif !sha_equal(pull_request.last_reviewed_sha, pull_request.current_sha)
  puts "unreviewed commits present. opening in brower."
  open_compare(pull_request, pull_request.last_reviewed_sha, pull_request.current_sha)

  puts
  puts "last feedback was:"
  puts pull_request.last_feedback
  puts

  output_choices(pull_request)
else
  puts "everything reviewed, status: #{find_maintainer_comment(pull_request.last_feedback)}"
end


if !pull_request.successful_cruises.empty?
  puts "successful cruises: #{pull_request.successful_cruises.join(", ")}"
elsif !pull_request.failing_cruises.empty?
  puts "only failing cruises."
  sh("open #{pull_request.failing_cruises.first}")
else
  puts "no current cruises."
end
puts

# base_sha1 = sh("git ls-remote #{pull_request.base_repo["ssh_url"]} #{pull_request.master_branch_name}").split(" ").first

sh "git co #{pull_request.master_branch_name}"
sh "hub co #{pull_url}"

merge_base = sh("git merge-base #{pull_request.master_branch_current_sha} #{pull_request.current_sha}").strip

if merge_base == pull_request.master_branch_current_sha
  puts "pull request is fast-forward-able."
else
  puts "pull request must be merged, merge base is #{merge_base}."
  open_compare(pull_request, merge_base, pull_request.master_branch_name)
end
puts

# require "pry"
# binding.pry


