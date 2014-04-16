require_relative "comment"

class PullRequest
  def initialize(data)
    @data = data
  end

  def data
    @data
  end

  def url
    data["html_url"]
  end

  def base_repo_html_url
    data["base"]["repo"]["html_url"]
  end

  def title
    data['title']
  end

  def created_at
    Time.parse(data['created_at'])
  end

  def base_repo
    data["base"]["repo"]
  end

  def base_branch_name
    data["base"]["ref"]
  end

  def number_of_changed_lines
    comparison["files"].map { |file| file["changes"] }.inject(:+)
  end

  def comparison
    @comparion ||= api_get("#{base_repo["url"]}/compare/#{base_branch_name}...#{current_sha}").data
  end

  def master_branch_current_sha
    master_branch_info["commit"]["sha"]
  end

  def master_branch_info
    @master_branch_info ||= api_get(base_repo["url"]+"/branches/#{master_branch_name}").data
  end

  def master_branch_name
    base_repo["default_branch"]
  end

  def current_sha
    data["head"]["sha"][0..6]
  end

  def comments
    @comments ||= retrieve_comments
  end

  def retrieve_comments
    results = api_get("#{data["_links"]["comments"]["href"]}?per_page=100").data.map do |raw_comment|
      Comment.new(raw_comment)
    end

    if results.size >= 100
      raise ">= 100 comments found and no pagination logic implemented yet, see: http://developer.github.com/v3/#pagination"
    end

    results
  end

  def api_get(url)
    tries = 0
    begin
      tries += 1
      Hub::Commands.__send__(:api_client).get(url)
    rescue Errno::ETIMEDOUT
      retry if tries <= 3
    end
  end

  def updated_at
    Time.parse(data["updated_at"])
  end

  def current_review
    last_review_comment.review if last_review_comment
  end

  def maintainers
    @maintainers ||= [api_get("https://api.github.com/user").data["login"]]
  end

  def maintainer_comments
    comments.select { |comment| maintainers.include? comment.author }
  end

  def last_review_comment
    maintainer_comments.select do |comment|
      comment.contains_review?
    end.last
  end

  def last_maintainer_status
    last_review_comment.status
  end

  def last_status_comment
    status_comments = comments.select do |comment|
      comment.status
    end.last
  end

  def last_status
    last_status_comment.status if last_status_comment
  end

  def pre_ok?
    comments.detect do |comment|
      comment.pre_ok?
    end
  end

  def current_approval
    last_review_comment.status
  end

end

