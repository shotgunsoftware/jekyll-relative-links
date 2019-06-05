# frozen_string_literal: true

module JekyllRelativeLinks
  class Generator < Jekyll::Generator
    attr_accessor :site, :config

    # Use Jekyll's native relative_url filter
    include Jekyll::Filters::URLFilters

    LINK_TEXT_REGEX = %r!(.*?)!.freeze
    FRAGMENT_REGEX = %r!(#.+?)?!.freeze
    INLINE_LINK_REGEX = %r!\[#{LINK_TEXT_REGEX}\]\(([^\)]+?)#{FRAGMENT_REGEX}\)!.freeze
    REFERENCE_LINK_REGEX = %r!^\s*?\[#{LINK_TEXT_REGEX}\]: (.+?)#{FRAGMENT_REGEX}\s*?$!.freeze
    SRC_LINK_REGEX = %r! src="#{LINK_TEXT_REGEX}"!
    LINK_REGEX = %r!(#{INLINE_LINK_REGEX}|#{REFERENCE_LINK_REGEX}|#{SRC_LINK_REGEX})!.freeze
    CONVERTER_CLASS = Jekyll::Converters::Markdown
    CONFIG_KEY = "relative_links"
    ENABLED_KEY = "enabled"
    COLLECTIONS_KEY = "collections"
    LOG_KEY = "Relative Links:"

    safe true
    priority :lowest

    def initialize(config)
      @config = config
    end

    def generate(site)
      return if disabled?

      @site    = site
      @context = context

      documents = site.pages
      documents = site.pages + site.docs_to_write if collections?

      documents.each do |document|
        next unless markdown_extension?(document.extname)
        next if document.is_a?(Jekyll::StaticFile)
        next if excluded?(document)

        replace_relative_links!(document)
      end
    end

    def replace_relative_links!(document)
      url_base = File.dirname(document.relative_path)
      return document if document.content.nil?

      document.content = document.content.dup.gsub(LINK_REGEX) do |original|
        link_type, link_text, relative_path, fragment = link_parts(Regexp.last_match)
        next original unless replaceable_link?(relative_path)

        path = path_from_root(relative_path, url_base)
        url  = url_for_path(path)
        next original unless url

        replacement_text(link_type, link_text, url, fragment)
      end
    rescue ArgumentError => e
      raise e unless e.to_s.start_with?("invalid byte sequence in UTF-8")
    end

    private

    def link_parts(matches)
      if matches[2]
        # if group 2 is populated, it's an inline link.
        link_type = :inline
        link_text     = matches[2]
        relative_path = matches[3]
        fragment      = matches[4]
      elsif matches[8]
        link_type = :src
        # We want to introduce a new "link" that should also be localized.
        # Instead of an anchor, however, this is an image source, and therefore
        # won't have text or a fragment.
        # If it's a src link, group 8 will be populated
        link_text     = ""
        relative_path = matches[8]
        fragment      = ""
      else
        # If groups 2 and 8 were not populated, it's a reference link.
        link_type = :reference
        link_text     = matches[5]
        relative_path = matches[6]
        fragment      = matches[7]
      end
      [link_type, link_text, relative_path, fragment]
    end

    def context
      @context ||= JekyllRelativeLinks::Context.new(site)
    end

    def markdown_extension?(extension)
      markdown_converter.matches(extension)
    end

    def markdown_converter
      @markdown_converter ||= site.find_converter_instance(CONVERTER_CLASS)
    end

    def url_for_path(path)
      target = potential_targets.find { |p| p.relative_path.sub(%r!\A/!, "") == path }
      relative_url(target.url) if target&.url
    end

    def potential_targets
      @potential_targets ||= site.pages + site.static_files + site.docs_to_write
    end

    def path_from_root(relative_path, url_base)
      relative_path.sub!(%r!\A/!, "")
      absolute_path = File.expand_path(relative_path, url_base)
      absolute_path.sub(%r!\A#{Regexp.escape(Dir.pwd)}/!, "")
    end

    def replacement_text(type, text, url, fragment = nil)
      url << fragment if fragment

      if type == :inline
        "[#{text}](#{url})"
      elsif type == :src
        " src=\"#{url}\""
      else
        "\n[#{text}]: #{url}"
      end
    end

    def absolute_url?(string)
      return unless string

      Addressable::URI.parse(string).absolute?
    rescue Addressable::URI::InvalidURIError
      nil
    end

    def fragment?(string)
      string&.start_with?("#")
    end

    def replaceable_link?(string)
      !fragment?(string) && !absolute_url?(string)
    end

    def option(key)
      config[CONFIG_KEY] && config[CONFIG_KEY][key]
    end

    def disabled?
      option(ENABLED_KEY) == false
    end

    def collections?
      option(COLLECTIONS_KEY) == true
    end

    def excluded?(document)
      return false unless option("exclude")

      entry_filter = if document.respond_to?(:collection)
                       document.collection.entry_filter
                     else
                       global_entry_filter
                     end

      entry_filter.glob_include?(option("exclude"), document.relative_path).tap do |excluded|
        Jekyll.logger.debug(LOG_KEY, "excluded #{document.relative_path}") if excluded
      end
    end

    def global_entry_filter
      @global_entry_filter ||= Jekyll::EntryFilter.new(site)
    end
  end
end
