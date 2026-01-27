// Back to Top functionality
// Handles smooth scrolling to the top of the page, supporting nested scroll containers
(function() {
    /**
     * Custom smooth scroll animation
     * @param {number} target Scroll target position
     * @param {number} duration Animation duration in ms
     * @param {HTMLElement|Window} element Element to scroll (defaults to window)
     */
    function smoothScroll(target, duration, element) {
        var el = element || window;
        var isWindow = (el === window);
        var start = isWindow ? (window.pageYOffset || document.documentElement.scrollTop) : el.scrollTop;
        var distance = target - start;
        var startTime = Date.now();
        
        function easeInOutQuad(t) {
            return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
        }
        
        function animateScroll() {
            var elapsed = Date.now() - startTime;
            var progress = Math.min(elapsed / duration, 1);
            var ease = easeInOutQuad(progress);
            
            var nextPos = start + distance * ease;
            
            if (isWindow) {
                window.scrollTo(0, nextPos);
            } else {
                el.scrollTop = nextPos;
            }
            
            if (progress < 1) {
                requestAnimationFrame(animateScroll);
            }
        }
        
        animateScroll();
    }

    document.addEventListener('DOMContentLoaded', function() {
        var btn = document.getElementById('back-to-top');
        if (!btn) {
            return;
        }

        /**
         * Last scrolled element to help click handler
         */
        var lastScrolledEl = window;

        // Use capture: true to catch scroll events from any nested container
        window.addEventListener('scroll', function(event) {
            var target = event.target;
            var scrollPos = 0;
            
            if (target === document || target === window || target === document.documentElement || target === document.body) {
                scrollPos = window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop;
                lastScrolledEl = window;
            } else if (target.scrollTop !== undefined) {
                scrollPos = target.scrollTop;
                lastScrolledEl = target;
            }
            
            if (scrollPos > 300) {
                if (!btn.classList.contains('show')) {
                    btn.classList.add('show');
                }
            } else {
                if (btn.classList.contains('show')) {
                    btn.classList.remove('show');
                }
            }
        }, true);

        btn.addEventListener('click', function(e) {
            e.preventDefault();
            
            // Try to find the best target position for window scroll
            var target = document.getElementById('main-menu') || 
                         document.querySelector('header') || 
                         document.getElementById('pagetop');
            
            var targetPos = 0;
            if (target) {
                var rect = target.getBoundingClientRect();
                targetPos = rect.top + (window.pageYOffset || document.documentElement.scrollTop);
                if (targetPos < 60) targetPos = 0;
            }
            
            // Scroll window
            if ('scrollBehavior' in document.documentElement.style) {
                window.scrollTo({
                    top: targetPos,
                    behavior: 'smooth'
                });
            } else {
                smoothScroll(targetPos, 800, window);
            }

            // Also scroll the last container that was scrolled, if it's not the window
            if (lastScrolledEl && lastScrolledEl !== window) {
                if ('scrollBehavior' in document.documentElement.style) {
                    if (typeof lastScrolledEl.scrollTo === 'function') {
                        lastScrolledEl.scrollTo({
                            top: 0,
                            behavior: 'smooth'
                        });
                    } else {
                        lastScrolledEl.scrollTop = 0;
                    }
                } else {
                    smoothScroll(0, 800, lastScrolledEl);
                }
            }
        });

        btn.addEventListener('keypress', function(e) {
            if (e.key === 'Enter' || e.key === ' ') {
                this.click();
            }
        });
    });
})();
