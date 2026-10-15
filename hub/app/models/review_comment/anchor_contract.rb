# Checks the saved element or area anchor for a ReviewComment.
class ReviewComment::AnchorContract < ActiveRecord::AssociatedObject
  ELEMENT_TOP_LEVEL_KEYS = %w[
    schemaVersion kind route selector accessibleName tagName selectedText rect viewport
    elementOffset
  ].freeze
  AREA_TOP_LEVEL_KEYS = %w[schemaVersion kind route path rect viewport elements].freeze
  AREA_ELEMENT_KEYS = %w[selector accessibleName tagName role textExcerpt rect].freeze
  ROUTE_KEYS = %w[pathname search hash].freeze
  RECT_KEYS = %w[x y width height].freeze
  VIEWPORT_KEYS = %w[width height scrollX scrollY].freeze
  POINT_KEYS = %w[x y].freeze

  # Adds validation errors for an unsupported or invalid review anchor.
  def validate_record
    anchor = record.anchor
    return invalid("must be a JSON object") if !anchor.is_a?(Hash)

    @anchor = anchor.deep_stringify_keys
    if @anchor["schemaVersion"] != ReviewComment::ANCHOR_SCHEMA_VERSION
      invalid("schemaVersion must be #{ReviewComment::ANCHOR_SCHEMA_VERSION}")
    elsif @anchor["kind"] == "element"
      validate_element_anchor
    elsif @anchor["kind"] == "area"
      validate_area_anchor
    else
      invalid("kind must be element or area")
    end
    validate_serialized_size
  end

  private

  # Checks the complete element anchor.
  def validate_element_anchor
    validate_exact_keys(@anchor, ELEMENT_TOP_LEVEL_KEYS)
    validate_route
    validate_element_context
    validate_rect(@anchor["rect"], "rect")
    validate_viewport
    validate_element_offset
  end

  # Checks the complete area anchor.
  def validate_area_anchor
    validate_exact_keys(@anchor, AREA_TOP_LEVEL_KEYS)
    validate_route
    validate_area_path
    validate_rect(@anchor["rect"], "rect")
    validate_area_size
    validate_viewport
    validate_area_elements
  end

  # Checks the browser path where the target was selected.
  def validate_route
    route = object(@anchor["route"], ROUTE_KEYS, "route")
    return if route.nil?

    validate_string \
      route["pathname"],
      "route.pathname",
      ReviewComment::PATHNAME_MAXIMUM_BYTES,
      required: true,
      prefix: "/"
    validate_string \
      route["search"],
      "route.search",
      ReviewComment::SEARCH_MAXIMUM_BYTES,
      prefix: "?"
    validate_string \
      route["hash"],
      "route.hash",
      ReviewComment::HASH_MAXIMUM_BYTES,
      prefix: "#"
  end

  # Checks the selector and details used to find the element again.
  def validate_element_context
    validate_string \
      @anchor["selector"],
      "selector",
      ReviewComment::SELECTOR_MAXIMUM_BYTES,
      required: true
    validate_string \
      @anchor["accessibleName"],
      "accessibleName",
      ReviewComment::ACCESSIBLE_NAME_MAXIMUM_BYTES
    validate_string \
      @anchor["tagName"],
      "tagName",
      ReviewComment::TAG_NAME_MAXIMUM_BYTES,
      required: true
    validate_string \
      @anchor["selectedText"],
      "selectedText",
      ReviewComment::SELECTED_TEXT_MAXIMUM_BYTES

    tag_name = @anchor["tagName"]
    return if !tag_name.is_a?(String) || tag_name.match?(/\A[a-z][a-z0-9-]*\z/)

    invalid("tagName must be a lowercase HTML tag name")
  end

  # Checks one saved page rectangle.
  def validate_rect(value, field)
    rect = object(value, RECT_KEYS, field)
    return if rect.nil?

    RECT_KEYS.each do |key|
      validate_number \
        rect[key],
        "#{field}.#{key}",
        minimum: 0,
        maximum: ReviewComment::GEOMETRY_ABSOLUTE_MAXIMUM
    end
  end

  # Checks the normalized stroke that redraws the selected region.
  def validate_area_path
    path = @anchor["path"]
    if !path.is_a?(Array)
      invalid("path must be an array")
      return
    end
    if !(2..ReviewComment::AREA_PATH_MAXIMUM_POINTS).cover?(path.length)
      invalid("path must contain between 2 and #{ReviewComment::AREA_PATH_MAXIMUM_POINTS} points")
    end

    path.each_with_index do |value, index|
      point = object(value, POINT_KEYS, "path[#{index}]")
      next if point.nil?

      POINT_KEYS.each do |key|
        validate_number point[key], "path[#{index}].#{key}", minimum: 0, maximum: 1
      end
    end
  end

  # Requires a region large enough to distinguish from an accidental tap.
  def validate_area_size
    rect = @anchor["rect"]
    return if !rect.is_a?(Hash)

    rect = rect.deep_stringify_keys
    width = rect["width"]
    height = rect["height"]
    return if !finite_number?(width) || !finite_number?(height)
    return if Math.hypot(width, height) >= ReviewComment::AREA_MINIMUM_DIAGONAL

    invalid("rect diagonal must be at least #{ReviewComment::AREA_MINIMUM_DIAGONAL} pixels")
  end

  # Checks the browser size and scroll position saved during selection.
  def validate_viewport
    viewport = object(@anchor["viewport"], VIEWPORT_KEYS, "viewport")
    return if viewport.nil?

    %w[width height].each do |key|
      validate_number \
        viewport[key],
        "viewport.#{key}",
        minimum: 1,
        maximum: ReviewComment::VIEWPORT_DIMENSION_MAXIMUM
    end
    %w[scrollX scrollY].each do |key|
      validate_number \
        viewport[key],
        "viewport.#{key}",
        minimum: 0,
        maximum: ReviewComment::GEOMETRY_ABSOLUTE_MAXIMUM
    end
  end

  # Checks that the saved click position stays between 0 and 1.
  def validate_element_offset
    offset = object(@anchor["elementOffset"], POINT_KEYS, "elementOffset")
    return if offset.nil?

    POINT_KEYS.each do |key|
      validate_number offset[key], "elementOffset.#{key}", minimum: 0, maximum: 1
    end
  end

  # Checks up to eight element details sampled inside an area.
  def validate_area_elements
    elements = @anchor["elements"]
    if !elements.is_a?(Array)
      invalid("elements must be an array")
      return
    end
    if elements.length > ReviewComment::AREA_ELEMENTS_MAXIMUM
      invalid("elements must contain at most #{ReviewComment::AREA_ELEMENTS_MAXIMUM} entries")
    end

    elements.each_with_index do |value, index|
      field = "elements[#{index}]"
      element = object(value, AREA_ELEMENT_KEYS, field)
      next if element.nil?

      validate_area_element(element, field)
    end
  end

  # Checks one element descriptor sampled inside an area.
  def validate_area_element(element, field)
    validate_string \
      element["selector"],
      "#{field}.selector",
      ReviewComment::SELECTOR_MAXIMUM_BYTES,
      required: true
    validate_string \
      element["accessibleName"],
      "#{field}.accessibleName",
      ReviewComment::ACCESSIBLE_NAME_MAXIMUM_BYTES
    validate_string \
      element["tagName"],
      "#{field}.tagName",
      ReviewComment::TAG_NAME_MAXIMUM_BYTES,
      required: true
    validate_string \
      element["role"],
      "#{field}.role",
      ReviewComment::AREA_ROLE_MAXIMUM_BYTES
    validate_string \
      element["textExcerpt"],
      "#{field}.textExcerpt",
      ReviewComment::AREA_TEXT_EXCERPT_MAXIMUM_BYTES
    validate_rect(element["rect"], "#{field}.rect")

    tag_name = element["tagName"]
    return if !tag_name.is_a?(String) || tag_name.match?(/\A[a-z][a-z0-9-]*\z/)

    invalid("#{field}.tagName must be a lowercase HTML tag name")
  end

  # Limits the JSON anchor to the allowed number of UTF-8 bytes.
  def validate_serialized_size
    serialized = JSON.generate(@anchor)
    return if serialized.bytesize <= ReviewComment::ANCHOR_MAXIMUM_BYTES

    invalid("must be #{ReviewComment::ANCHOR_MAXIMUM_BYTES} UTF-8 bytes or fewer")
  rescue JSON::GeneratorError
    invalid("must contain valid JSON values")
  end

  # Returns a nested object after checking its expected fields.
  def object(value, keys, field)
    if !value.is_a?(Hash)
      invalid("#{field} must be an object")
      return
    end

    value = value.deep_stringify_keys
    validate_exact_keys(value, keys, field)
    value
  end

  # Rejects missing or unsupported fields.
  def validate_exact_keys(value, expected, field = nil)
    actual = value.keys
    missing = expected - actual
    extra = actual - expected
    label = field.present? ? "#{field} " : ""
    invalid("#{label}is missing: #{missing.join(", ")}") if missing.any?
    invalid("#{label}contains unsupported fields: #{extra.join(", ")}") if extra.any?
  end

  # Checks one UTF-8 string and its optional starting character.
  def validate_string(value, field, maximum_bytes, required: false, prefix: nil)
    if !value.is_a?(String) || !value.valid_encoding?
      invalid("#{field} must be a UTF-8 string")
      return
    end
    invalid("#{field} cannot be blank") if required && value.blank?
    invalid("#{field} must be #{maximum_bytes} UTF-8 bytes or fewer") if value.bytesize > maximum_bytes
    return if prefix.nil? || value.empty? || value.start_with?(prefix)

    invalid("#{field} must start with #{prefix}")
  end

  # Checks one number against its allowed range.
  def validate_number(value, field, minimum:, maximum:)
    if !finite_number?(value)
      invalid("#{field} must be a finite number")
      return
    end
    return if value >= minimum && value <= maximum

    invalid("#{field} must be between #{minimum} and #{maximum}")
  end

  # Reports whether a value is a finite Ruby number.
  def finite_number?(value)
    value.is_a?(Numeric) && value.finite?
  end

  # Adds one anchor error to the comment.
  def invalid(message)
    record.errors.add(:anchor, message)
  end
end
