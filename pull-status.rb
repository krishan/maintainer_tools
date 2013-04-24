#!/usr/bin/env ruby

require "rubygems"

require "restclient"

gem "hub", "= 1.10.1"
require "hub"

require_relative "pull_request"

include Hub::Context
include Hub::GitHubAPI::HttpMethods

def sh(cmd)
  raise "newline in command" if cmd.include?("\n")

  output = %x{#{cmd} 2>&1}
  raise "'command #{cmd}' failed with #{output}" unless $? == 0

  output
end

def local_repo_dir(project_name)
  local_repos_mapping_file = File.expand_path("~/.config/maintainer_tools/local_repositories.yml")

  if !File.exists?(local_repos_mapping_file)
    raise "missing configuration file: `#{local_repos_mapping_file}`"
  end

  project_directory_mapping = YAML.load(File.read(local_repos_mapping_file))

  raw_local_repo_dir = project_directory_mapping[project_name]

  if !raw_local_repo_dir
    raise "no local repository configured for project `#{project_name}`, check `#{local_repos_mapping_file}`"
  end

  File.expand_path(raw_local_repo_dir)
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
          map do |url_string|
            url = replacement_cruise_url(URI.parse(url_string))

            output =
              begin
                RestClient.get(url.to_s)
              rescue RestClient::ResourceNotFound
              end

            {:url => url, :output => output}
          end.
          reject do |cruise|
            cruise[:output] == nil
          end
      end
  end

  def replacement_cruise_url(source_url)
    url = source_url.dup

    # when accessing "cruise.infopark" through a tunnel, enable this code
    if false
      url.host = "localhost"
      url.port = 10080
    end

    url
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

module Reporting

  def show_cruises
    if !successful_cruises.empty?
      puts "successful cruises: #{successful_cruises.join(", ")}"
    elsif !failing_cruises.empty?
      puts "only failing cruises:"
      puts failing_cruises.first
    else
      puts "no current cruises."
    end
    puts
  end

  def show_pending_merges
    sh "git co #{master_branch_name}"
    sh "hub co #{url}"

    merge_base = find_merge_base_with_pull

    if merge_base == master_branch_current_sha
      puts "pull request is fast-forward-able."
    else
      puts "pull request must be merged, merge base is #{merge_base}."
      puts compare_url(merge_base, master_branch_name)
    end
    puts
  end

  def show_review_status
    if !current_review
      puts "never reviewed."

      puts "#{url}/files?w=1"
      puts diff_chunks_command("#{current_sha} ^#{master_branch_name}")
      puts name_status_command

      puts
      output_choices
    elsif !sha_equal(current_review.sha, current_sha)
      puts
      puts "last approval from maintainer was: #{current_review}"
      puts

      if lmc = maintainer_comments.last
        puts "last maintainer comment:"
        puts lmc.body.gsub(/\r/, "")
        puts
      end

      puts "unreviewed commits: "
      puts compare_url(current_review.sha, current_sha)
      puts diff_chunks_command("#{current_sha} ^#{master_branch_name} ^#{current_review.sha}")
      puts name_status_command

      puts
      output_choices
    else
      puts "everything reviewed, approval: #{current_review}"
    end
  end

  private

  def output_choices
    puts "possible choices:"
    puts "OK (#{current_sha})"
    puts "FEEDBACK (#{current_sha})"
    puts
  end

  def compare_url(from, to)
    "#{base_repo_html_url}/compare/#{from}...#{to}"
  end

  def sha_equal(a, b)
    a[0..6] == b[0..6]
  end

  def find_merge_base(master_rev, branch_rev)
    sh("git merge-base #{master_rev} #{branch_rev}").strip
  end

  def find_merge_base_with_pull
    current_branch_name = sh("git rev-parse --abbrev-ref HEAD").strip
    retried = false

    begin
      find_merge_base(master_branch_current_sha, current_sha)
    rescue
      raise if retried
      sh "git co #{master_branch_name}"
      sh "git pull"
      retried = true
      retry
    ensure
      sh "git checkout #{current_branch_name}"
    end
  end


  def diff_chunks_command(args)
    "cd #{Dir.pwd} && diff_chunks #{args}"
  end

  def name_status_command
    "cd #{Dir.pwd} && git diff #{master_branch_name}...#{current_sha} --name-status"
  end

end

PullRequest.__send__(:include, Reporting)

### MAIN COMMAND STARTS HERE

pull_url = ARGV[0]
unless pull_url.match(/\/([^\/]+)\/pull\/(\d+)/)
  puts "usage: pull-status.rb <github pull url>"
  exit
end

project_name = $1
pull_id = $2

Dir.chdir local_repo_dir(project_name)

project = local_repo.main_project

api = Hub::Commands.__send__(:api_client)

pull_request = PullRequest.new(api.pullrequest_info(project, pull_id))

pull_request.show_cruises

pull_request.show_pending_merges

pull_request.show_review_status

# require "pry";binding.pry

