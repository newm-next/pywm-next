precision mediump float;
uniform float params_float[11];
uniform float alpha;
varying vec2 v_texcoord;

uniform float width;
uniform float height;

void main() {
    if(v_texcoord.x*width > width - params_float[9] &&  v_texcoord.y*height > height - params_float[9]){
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(width - params_float[9], height - params_float[9])) > params_float[9]) discard;
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(width - params_float[9], height - params_float[9])) < params_float[9] - params_float[10]) discard;

    }else if(v_texcoord.x*width > width - params_float[9] &&  v_texcoord.y*height < params_float[9]){
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(width - params_float[9], params_float[9])) > params_float[9]) discard;
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(width - params_float[9], params_float[9])) < params_float[9] - params_float[10]) discard;

    }else if(v_texcoord.x*width < params_float[9] &&  v_texcoord.y*height > height - params_float[9]){
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(params_float[9], height - params_float[9])) > params_float[9]) discard;
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(params_float[9], height - params_float[9])) < params_float[9] - params_float[10]) discard;

    }else if(v_texcoord.x*width < params_float[9] &&  v_texcoord.y*height < params_float[9]){
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(params_float[9], params_float[9])) > params_float[9]) discard;
        if(length(vec2(v_texcoord.x*width, v_texcoord.y*height) - 
                    vec2(params_float[9], params_float[9])) < params_float[9] - params_float[10]) discard;

    }else{
        if(v_texcoord.x*width > params_float[10] && v_texcoord.x*width < width - params_float[10] &&
            v_texcoord.y*height > params_float[10] && v_texcoord.y*height < height - params_float[10]) discard;
    }

		vec4 color1 = vec4(
				params_float[0],
				params_float[1],
				params_float[2],
				1.
				) * params_float[3] * alpha;

		vec4 color2 = vec4(
				params_float[4],
				params_float[5],
				params_float[6],
				1.
				) * params_float[7] * alpha;

		float angle = params_float[8];
		angle -= (360.0 * floor(angle / 360.0));
		angle *= 0.01745532925;
		vec2 direction = vec2(cos(angle), sin(angle));
		float gradient_factor = dot(v_texcoord - 0.5, direction) + 0.5;

		gl_FragColor = mix(color1, color2, gradient_factor);
}

